import Foundation

private enum Failure: Error { case assertion(String), stopStream }
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure.assertion(message) }
}

private actor Transport {
    var receivers: [@Sendable (Data) async throws -> Void] = []
    var cancellations = 0
    var count: Int { receivers.count }

    func run(receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        receivers.append(receive)
        do {
            while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
        } catch {
            cancellations += 1
            throw error
        }
    }

    func send(_ frame: String, connection: Int? = nil) async throws {
        guard !receivers.isEmpty else { throw Failure.assertion("No connection") }
        try await receivers[connection ?? receivers.count - 1](Data(frame.utf8))
    }
}

private actor RejectedTransport {
    var attempts = 0
    func run() throws { attempts += 1; throw PhiSyncInvalidationError.http(404) }
}

private actor HTTPState {
    var parser = PhiSyncInvalidationParser()
    var events: [PhiSyncInvalidationEvent] = []
    func receive(_ data: Data, stopAfterReady: Bool = false) throws {
        events += try parser.feed(data)
        if stopAfterReady && events.contains(.ready) { throw Failure.stopStream }
    }
}

private actor TokenGate {
    var continuation: CheckedContinuation<String?, Never>?
    var waiting: Bool { continuation != nil }
    func token() async -> String? { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(returning: "test-token"); continuation = nil }
}

@MainActor
private final class PullState {
    var demands: [PhiSyncInvalidationDemand] = []
    var releasePull: CheckedContinuation<Void, Never>?
    var block = false
}

@main
struct InvalidationTests {
    @MainActor
    static func eventually(_ message: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw Failure.assertion(message)
    }

    static func frame(_ namespace: String = "chromium:phi", types: [Int] = [2000], source: String = "peer") throws -> String {
        let payload = try JSONEncoder().encode(PhiSyncInvalidation(namespace: namespace, dataTypes: types, sourceClientID: source))
        return "event: invalidate\ndata: " + String(decoding: payload, as: UTF8.self) + "\n\n"
    }

    static func parserTests() throws {
        let wire = "\u{feff}: heartbeat\r\nevent: ready\r\ndata: {}\r\n\r\n" + (try frame())
        for size in [1, 2, 3, 7, 1024] {
            var parser = PhiSyncInvalidationParser()
            var events: [PhiSyncInvalidationEvent] = []
            let bytes = Array(wire.utf8)
            for start in stride(from: 0, to: bytes.count, by: size) {
                events += try parser.feed(Data(bytes[start..<min(start + size, bytes.count)]))
            }
            try expect(events == [.heartbeat, .ready, .invalidate(PhiSyncInvalidation(namespace: "chromium:phi", dataTypes: [2000], sourceClientID: "peer"))], "Fragmented CRLF/BOM at size \(size)")
        }
        var unknown = PhiSyncInvalidationParser()
        try expect(try unknown.feed(Data("event: future\ndata: arbitrary\n\n".utf8)).isEmpty, "Unknown events must be ignored")
        var partial = PhiSyncInvalidationParser()
        try expect(try partial.feed(Data("event: ready\ndata: {}\n".utf8)).isEmpty, "Partial event dispatched before blank line")
        for invalid in ["event: ready\ndata: []\n\n", "event: invalidate\ndata: {}\n\n", try frame("other:phi"), try frame(types: [-1]), try frame(source: String(repeating: "x", count: 257))] {
            var parser = PhiSyncInvalidationParser()
            do { _ = try parser.feed(Data(invalid.utf8)); throw Failure.assertion("Accepted malformed event") }
            catch is PhiSyncInvalidationError { }
        }
        var oversized = PhiSyncInvalidationParser()
        do {
            _ = try oversized.feed(Data(String(repeating: "x", count: 16 * 1024 + 1).utf8))
            throw Failure.assertion("Unbounded SSE line")
        } catch is PhiSyncInvalidationError { }
        print("PASS parser: fragmented CR/LF/BOM, incomplete/unknown frames, validation and bounds")
    }

    @MainActor
    static func schedulerTests() async throws {
        let transport = Transport()
        var time: TimeInterval = 100
        let state = PullState()
        var config = PhiSyncInvalidationCoordinator.Configuration()
        config.tickInterval = 3600
        config.coalescingInterval = 0.01
        config.retryDelay = { _ in 0.01 }
        let coordinator = PhiSyncInvalidationCoordinator(configuration: config, now: { time },
            stream: { receive in try await transport.run(receive: receive) },
            pull: { demand in
                state.demands.append(demand)
                if state.block { await withCheckedContinuation { state.releasePull = $0 } }
            })
        defer { coordinator.stop(); state.releasePull?.resume() }
        coordinator.start(); coordinator.start()
        try await eventually("Initial catch-up and single connection") {
            let connections = await transport.count
            return state.demands.count == 1 && connections == 1
        }
        try expect(state.demands == [.catchUp], "Missing initial recovery")
        try await transport.send("event: ready\ndata: {}\n\n")
        try await eventually("Ready catch-up") { state.demands.count == 2 }
        try expect(coordinator.isHealthy, "Ready did not mark healthy")
        try await transport.send(try frame("chromium:profile-a", types: [37702], source: "own"))
        try await transport.send(try frame("chromium:profile-a", types: [88610], source: "peer"))
        try await eventually("Merged type hints") { state.demands.count == 3 }
        try expect(state.demands.last == .changes([PhiSyncInvalidation(namespace: "chromium:profile-a", dataTypes: [37702, 88610], sourceClientID: "")]), "Mixed sources suppressed a peer change")

        // Block one pull and flood it; only one follow-up may accumulate.
        state.block = true
        coordinator.requestCatchUp()
        try await eventually("Blocking pull did not start") { state.releasePull != nil }
        let before = state.demands.count
        for _ in 0..<100 { try await transport.send(try frame()) }
        try await Task.sleep(nanoseconds: 30_000_000)
        try expect(state.demands.count == before, "Concurrent pulls escaped single-flight guard")
        state.block = false
        let release = state.releasePull; state.releasePull = nil; release?.resume()
        try await eventually("Follow-up pull missing") { state.demands.count == before + 1 }

        // Many individually valid type lists must not grow an unbounded union.
        let boundedCount = state.demands.count
        try await transport.send(try frame(types: Array(1...64)))
        try await transport.send(try frame(types: Array(65...128)))
        try await eventually("Bounded union missing") { state.demands.count == boundedCount + 1 }
        try expect(state.demands.last == .catchUp, "Merged metadata exceeded bound instead of catching up")

        // A recent heartbeat permits the longer interval without firing the stall watchdog.
        time = 399
        try await transport.send(": heartbeat\n\n")
        coordinator.tick()
        try await Task.sleep(nanoseconds: 20_000_000)
        let healthyCount = state.demands.count
        time = 400; coordinator.tick()
        try await eventually("Healthy 300-second fallback missing") { state.demands.count == healthyCount + 1 }

        time = 445; coordinator.tick()
        try await eventually("Silent stream not reconnected") { await transport.count == 2 }
        try expect(!coordinator.isHealthy, "Stalled stream stayed healthy")
        let unhealthyCount = state.demands.count
        time = 505; coordinator.tick()
        try await eventually("Unhealthy 60-second fallback missing") { state.demands.count == unhealthyCount + 1 }

        // Simulate old stream data arriving after token refresh/account teardown.
        coordinator.reconnect()
        try await eventually("Explicit reconnect") { await transport.count >= 3 }
        do { try await transport.send("event: ready\ndata: {}\n\n", connection: 0); throw Failure.assertion("Old callback accepted") }
        catch is CancellationError { }
        coordinator.stop()
        let stoppedCount = state.demands.count
        coordinator.requestCatchUp(); coordinator.tick(); coordinator.foregroundOrWake()
        try await Task.sleep(nanoseconds: 30_000_000)
        try expect(state.demands.count == stoppedCount && !coordinator.isHealthy, "Stopped coordinator scheduled work")
        try await eventually("Transport not cancelled") { await transport.cancellations >= 1 }
        print("PASS scheduling: recovery, coalescing, single-flight, adaptive polling, stall watchdog, stale callback and teardown")
    }

    @MainActor
    static func pairingCatchUpTests() async throws {
        let transport = Transport()
        let state = PullState()
        let engine = SpaceGateEngine()
        let fixture = SpaceGateFixture()
        var config = PhiSyncInvalidationCoordinator.Configuration()
        config.tickInterval = 3600
        config.coalescingInterval = 0.01
        let coordinator = PhiSyncInvalidationCoordinator(configuration: config, now: { 100 },
            stream: { receive in try await transport.run(receive: receive) },
            pull: { demand in state.demands.append(demand) })
        fixture.phiSyncEngine = engine
        fixture.phiInvalidationCoordinator = coordinator
        defer {
            coordinator.stop()
            engine.release?.resume()
            ProfilePairingGate.joinPairingPending = true
        }
        coordinator.start()
        try await eventually("Initial catch-up") {
            let connections = await transport.count
            return state.demands.count == 1 && connections == 1
        }
        try await transport.send("event: ready\ndata: {}\n\n")
        try await eventually("Healthy stream catch-up") { state.demands.count == 2 }
        fixture.refresh()
        try await eventually("Pairing gate did not close") { engine.transitions == 1 }

        // A clean joining Mac has no local edits or peer hint to wake it.
        // Hold the engine queue to ensure catch-up cannot overtake the gate.
        engine.hold = true
        ProfilePairingGate.joinPairingPending = false
        fixture.refresh()
        try await eventually("Opening gate was not queued") { engine.release != nil }
        try await Task.sleep(nanoseconds: 30_000_000)
        try expect(state.demands.count == 2, "Catch-up overtook the queued gate")
        engine.hold = false
        let release = engine.release; engine.release = nil; release?.resume()
        try await eventually("Finishing pairing must pull without a hint or polling tick") {
            state.demands.count == 3 && engine.enabled
        }
        try expect(state.demands.last == .catchUp, "Pairing requested only a partial refresh")
        fixture.refresh(); fixture.refresh()
        try await Task.sleep(nanoseconds: 30_000_000)
        try expect(state.demands.count == 3 && engine.transitions == 2, "Repeated notifications caused replay churn")

        // A gate queued for a departed account cannot wake a replacement engine.
        ProfilePairingGate.joinPairingPending = true
        fixture.refresh()
        try await eventually("Gate did not close again") { !engine.enabled }
        engine.hold = true
        ProfilePairingGate.joinPairingPending = false
        fixture.refresh()
        try await eventually("Second gate was not queued") { engine.release != nil }
        coordinator.stop()
        let replacementState = PullState()
        let replacementTransport = Transport()
        let replacement = PhiSyncInvalidationCoordinator(configuration: config, now: { 100 },
            stream: { receive in try await replacementTransport.run(receive: receive) },
            pull: { demand in replacementState.demands.append(demand) })
        defer { replacement.stop() }
        fixture.phiInvalidationCoordinator = replacement
        fixture.phiSyncEngine = SpaceGateEngine()
        replacement.start()
        try await eventually("Replacement account did not start") { replacementState.demands.count == 1 }
        engine.hold = false
        let retired = engine.release; engine.release = nil; retired?.resume()
        try await Task.sleep(nanoseconds: 30_000_000)
        try expect(state.demands.count == 3, "Retired coordinator scheduled a catch-up")
        try expect(replacementState.demands.count == 1, "Old gate completion woke the replacement account")
        print("PASS pairing: immediate ordered catch-up, unchanged-gate deduplication and retirement")
    }

    @MainActor
    static func unavailableServerTests() async throws {
        let transport = RejectedTransport()
        let state = PullState()
        var time: TimeInterval = 100
        var config = PhiSyncInvalidationCoordinator.Configuration()
        config.tickInterval = 3600
        config.coalescingInterval = 0.001
        config.retryDelay = { _ in 0.01 }
        let coordinator = PhiSyncInvalidationCoordinator(configuration: config, now: { time },
            stream: { _ in try await transport.run() }, pull: { state.demands.append($0) })
        defer { coordinator.stop() }
        coordinator.start()
        try await eventually("Older server did not retry") { await transport.attempts >= 3 }
        try expect(!coordinator.isHealthy && state.demands == [.catchUp], "HTTP failures disabled fallback")
        time = 160; coordinator.tick()
        try await eventually("404 server fallback did not pull") { state.demands.count == 2 }
        coordinator.foregroundOrWake()
        try await eventually("Wake did not request immediate recovery") { state.demands.count == 3 }
        coordinator.stop()
        let stoppedAttempts = await transport.attempts
        try await Task.sleep(nanoseconds: 30_000_000)
        let finalAttempts = await transport.attempts
        try expect(finalAttempts == stoppedAttempts, "Retry continued after stop")
        print("PASS unavailable server: retry, unhealthy fallback, wake catch-up and backoff cancellation")
    }

    @MainActor
    static func httpTests() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            try await PhiSyncInvalidationHTTPStream.run(session: session, baseURL: "https://example.invalid", deviceID: "test", tokenProvider: { nil }, receive: { _ in })
            throw Failure.assertion("Missing token made request")
        } catch PhiSyncInvalidationError.missingToken { }
        do {
            try await PhiSyncInvalidationHTTPStream.run(session: session, baseURL: "http://example.invalid", deviceID: "test", tokenProvider: { "secret" }, receive: { _ in })
            throw Failure.assertion("Cleartext remote origin accepted")
        } catch PhiSyncInvalidationError.invalidURL { }
        let policy = PhiSyncInvalidationRedirectPolicy()
        let url = URL(string: "https://example.invalid")!
        let task = session.dataTask(with: url)
        var acceptedRedirect = true
        policy.urlSession(session, task: task,
                          willPerformHTTPRedirection: HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!,
                          newRequest: URLRequest(url: URL(string: "https://other.invalid")!)) { acceptedRedirect = $0 != nil }
        try expect(!acceptedRedirect, "Bearer redirect allowed")
        print("PASS HTTP guards: token required, secure origin, redirects refused")
    }

    @MainActor
    static func liveHTTPTests(baseURL: String) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let state = HTTPState()
        try await PhiSyncInvalidationHTTPStream.run(session: session, baseURL: baseURL + "/stream/",
            deviceID: "native & device", tokenProvider: { "test-token" }, receive: { try await state.receive($0) })
        let events = await state.events
        try expect(events == [.ready, .invalidate(PhiSyncInvalidation(namespace: "chromium:phi", dataTypes: [2000], sourceClientID: "peer"))],
                   "Real streaming response was buffered, truncated or misparsed")

        for (path, status) in [("unauthorized", 401), ("redirect", 302)] {
            do {
                try await PhiSyncInvalidationHTTPStream.run(session: session, baseURL: baseURL + "/" + path,
                    deviceID: "native & device", tokenProvider: { "test-token" }, receive: { _ in })
                throw Failure.assertion("Accepted HTTP \(status)")
            } catch PhiSyncInvalidationError.http(let actual) {
                try expect(actual == status, "Unexpected status \(actual)")
            }
        }
        do {
            try await PhiSyncInvalidationHTTPStream.run(session: session, baseURL: baseURL + "/wrong-type",
                deviceID: "native & device", tokenProvider: { "test-token" }, receive: { _ in })
            throw Failure.assertion("Accepted non-SSE content type")
        } catch PhiSyncInvalidationError.invalidResponse { }

        // A receiver error must cancel the underlying streaming URLSessionTask.
        let interrupted = HTTPState()
        do {
            try await PhiSyncInvalidationHTTPStream.run(session: session, baseURL: baseURL + "/hold",
                deviceID: "native & device", tokenProvider: { "test-token" },
                receive: { try await interrupted.receive($0, stopAfterReady: true) })
            throw Failure.assertion("Receiver error was swallowed")
        } catch Failure.stopStream { }

        // Account teardown can happen while AuthManager is obtaining a token.
        let gate = TokenGate()
        let cancelled = Task {
            try await PhiSyncInvalidationHTTPStream.run(session: session, baseURL: baseURL + "/cancelled-token",
                deviceID: "native & device", tokenProvider: { await gate.token() }, receive: { _ in })
        }
        try await eventually("Token provider did not suspend") { await gate.waiting }
        cancelled.cancel()
        await gate.release()
        do { try await cancelled.value; throw Failure.assertion("Cancelled token request escaped") }
        catch is CancellationError { }

        func metrics() async throws -> [String: Int] {
            let (data, _) = try await session.data(from: URL(string: baseURL + "/metrics")!)
            return try JSONDecoder().decode([String: Int].self, from: data)
        }
        try await eventually("Underlying stream stayed open after receiver failed") {
            (try? await metrics()["closed_streams"]) == 1
        }
        let counts = try await metrics()
        try expect(counts["redirects_followed"] == 0, "Transport followed redirect")
        try expect(counts["cancelled_token_requests"] == 0, "Cancelled request reached server")
        print("PASS live HTTP: bearer/header/query contract, streaming frames, status/MIME rejection, redirect refusal, cancellation")
    }

    static func main() async {
        do {
            try parserTests()
            try await schedulerTests()
            try await pairingCatchUpTests()
            try await unavailableServerTests()
            try await httpTests()
            guard CommandLine.arguments.count == 2 else { throw Failure.assertion("Missing loopback fixture URL") }
            try await liveHTTPTests(baseURL: CommandLine.arguments[1])
            print("All hostless sync invalidation tests passed")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
