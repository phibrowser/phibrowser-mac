import Foundation
import XCTest
@testable import Phi

final class ServiceBrokerChannelStoreTests: XCTestCase {
    private let owner = BrokerSenderContext(extensionID: "sidecar", profileID: "profile-a", accountID: "account-a")

    func testChannelIsBoundToCreatingSender() async throws {
        let stream = FakeBrokerHTTPStream()
        let store = makeStore(httpStream: stream)
        let opened = try await store.openHTTPStream(owner: owner, request: request())
        let otherOwner = BrokerSenderContext(extensionID: "sidecar", profileID: "profile-b", accountID: "account-a")

        await assertChannelError(.ownerMismatch) {
            _ = try await store.pullHTTP(owner: otherOwner, channelID: opened.channelID)
        }

        await store.close(owner: owner, channelID: opened.channelID, code: nil, reason: nil)
    }

    func testOnlyOnePullMayWaitPerChannel() async throws {
        let stream = FakeBrokerHTTPStream()
        let store = makeStore(httpStream: stream, pullTimeout: .seconds(1))
        let opened = try await store.openHTTPStream(owner: owner, request: request())
        let firstPull = Task { try await store.pullHTTP(owner: owner, channelID: opened.channelID) }
        try await Task.sleep(for: .milliseconds(10))

        await assertChannelError(.pullAlreadyPending) {
            _ = try await store.pullHTTP(owner: self.owner, channelID: opened.channelID)
        }

        stream.finish()
        _ = try await firstPull.value
    }

    func testPullWaitsUntilChunkOrTimeout() async throws {
        let stream = FakeBrokerHTTPStream()
        let store = makeStore(httpStream: stream, pullTimeout: .milliseconds(40))
        let opened = try await store.openHTTPStream(owner: owner, request: request())

        let timeout = try await store.pullHTTP(owner: owner, channelID: opened.channelID)
        XCTAssertEqual(timeout.event, .timeout)

        let waitingPull = Task { try await store.pullHTTP(owner: owner, channelID: opened.channelID) }
        try await Task.sleep(for: .milliseconds(10))
        stream.send(Data("ready".utf8))

        let response = try await waitingPull.value
        XCTAssertEqual(response.event, .data(sequence: 0, data: Data("ready".utf8)))
        await store.close(owner: owner, channelID: opened.channelID, code: nil, reason: nil)
    }

    func testHTTPChunksHaveMonotonicSequenceNumbers() async throws {
        let stream = FakeBrokerHTTPStream()
        let store = makeStore(httpStream: stream)
        let opened = try await store.openHTTPStream(owner: owner, request: request())

        stream.send(Data("first".utf8))
        stream.send(Data("second".utf8))
        stream.finish()

        let first = try await store.pullHTTP(owner: owner, channelID: opened.channelID)
        let second = try await store.pullHTTP(owner: owner, channelID: opened.channelID)
        let end = try await store.pullHTTP(owner: owner, channelID: opened.channelID)
        XCTAssertEqual(first.event, .data(sequence: 0, data: Data("first".utf8)))
        XCTAssertEqual(second.event, .data(sequence: 1, data: Data("second".utf8)))
        XCTAssertEqual(end.event, .end)
    }

    func testCancelUnblocksPendingPullAndClosesUpstream() async throws {
        let stream = FakeBrokerHTTPStream()
        let store = makeStore(httpStream: stream, pullTimeout: .seconds(1))
        let opened = try await store.openHTTPStream(owner: owner, request: request())
        let pull = Task { try await store.pullHTTP(owner: owner, channelID: opened.channelID) }
        await Task.yield()

        await store.close(owner: owner, channelID: opened.channelID, code: nil, reason: nil)

        let response = try await pull.value
        XCTAssertEqual(response.event, .end)
        XCTAssertTrue(stream.isCancelled)
    }

    func testIdleExpiryRemovesChannel() async throws {
        let stream = FakeBrokerHTTPStream()
        let store = makeStore(httpStream: stream, idleTimeout: .milliseconds(30))
        let opened = try await store.openHTTPStream(owner: owner, request: request())

        try await Task.sleep(for: .milliseconds(80))

        await assertChannelError(.channelNotFound) {
            _ = try await store.pullHTTP(owner: self.owner, channelID: opened.channelID)
        }
        XCTAssertTrue(stream.isCancelled)
    }

    func testBackpressureLimitClosesChannel() async throws {
        let stream = FakeBrokerHTTPStream()
        let store = makeStore(httpStream: stream, unacknowledgedWindowBytes: 4)
        let opened = try await store.openHTTPStream(owner: owner, request: request())

        stream.send(Data("12345".utf8))
        try await Task.sleep(for: .milliseconds(10))

        let response = try await store.pullHTTP(owner: owner, channelID: opened.channelID)
        XCTAssertEqual(
            response.event,
            .failure(code: .flowControlTimeout, message: "Channel backpressure limit exceeded.")
        )
        XCTAssertTrue(stream.isCancelled)
    }

    func testWebSocketChannelSendPullAndCloseRoundTrip() async throws {
        let socket = FakeBrokerWebSocket()
        let store = ServiceBrokerChannelStore(
            configuration: ServiceBrokerChannelConfiguration(
                bridgeChunkBytes: 64,
                webSocketMessageBytes: 1_024,
                unacknowledgedWindowBytes: 1_024,
                pullTimeout: .seconds(1),
                idleTimeout: .seconds(1)
            ),
            httpStreamOpener: { _ in throw BrokerChannelError.invalidChannelKind },
            webSocketOpener: { _, _ in socket.source }
        )
        let opened = try await store.openWebSocket(
            owner: owner,
            path: "/ws/phi-agent/execute",
            headers: [:]
        )
        let outgoing = BrokerWebSocketFrame(kind: .text, data: Data("request".utf8))
        try await store.sendWebSocket(owner: owner, channelID: opened.channelID, frame: outgoing)
        socket.receive(.frame(BrokerWebSocketFrame(kind: .binary, data: Data([1, 2, 3]))))
        socket.receive(.close(code: 1000, reason: "done"))

        let frame = try await store.pullWebSocket(owner: owner, channelID: opened.channelID)
        let close = try await store.pullWebSocket(owner: owner, channelID: opened.channelID)

        XCTAssertEqual(socket.sentFrames, [outgoing])
        XCTAssertEqual(frame.event, .frame(BrokerWebSocketFrame(kind: .binary, data: Data([1, 2, 3]))))
        XCTAssertEqual(close.event, .close(code: 1000, reason: "done"))
    }

    private func request() -> BrokerHTTPRequest {
        BrokerHTTPRequest(service: .phiAgent, path: "/stream")
    }

    private func makeStore(
        httpStream: FakeBrokerHTTPStream,
        pullTimeout: Duration = .seconds(1),
        idleTimeout: Duration = .seconds(1),
        unacknowledgedWindowBytes: Int = 1_024
    ) -> ServiceBrokerChannelStore {
        ServiceBrokerChannelStore(
            configuration: ServiceBrokerChannelConfiguration(
                bridgeChunkBytes: 64,
                webSocketMessageBytes: 1_024,
                unacknowledgedWindowBytes: unacknowledgedWindowBytes,
                pullTimeout: pullTimeout,
                idleTimeout: idleTimeout
            ),
            httpStreamOpener: { _ in httpStream.source },
            webSocketOpener: { _, _ in throw BrokerChannelError.invalidChannelKind }
        )
    }
}

private final class FakeBrokerWebSocket: @unchecked Sendable {
    private let condition = NSCondition()
    private var incoming = [Result<BrokerWebSocketEvent, Error>]()
    private var outgoing = [BrokerWebSocketFrame]()
    private var closed = false

    var source: BrokerWebSocketSource {
        BrokerWebSocketSource(
            send: { [self] frame in record(frame) },
            receive: { [self] in try await next() },
            close: { [self] _, _ in closeNow() }
        )
    }

    var sentFrames: [BrokerWebSocketFrame] {
        condition.lock()
        defer { condition.unlock() }
        return outgoing
    }

    func receive(_ event: BrokerWebSocketEvent) {
        condition.lock()
        incoming.append(.success(event))
        condition.broadcast()
        condition.unlock()
    }

    private func record(_ frame: BrokerWebSocketFrame) {
        condition.lock()
        outgoing.append(frame)
        condition.unlock()
    }

    private func closeNow() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    private func next() async throws -> BrokerWebSocketEvent {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { [self] in
                condition.lock()
                while incoming.isEmpty && !closed { condition.wait() }
                let result = incoming.isEmpty
                    ? Result<BrokerWebSocketEvent, Error>.failure(ServiceBrokerWebSocketError.cancelled)
                    : incoming.removeFirst()
                condition.unlock()
                continuation.resume(with: result)
            }
        }
    }
}

private final class FakeBrokerHTTPStream: @unchecked Sendable {
    private let condition = NSCondition()
    private var values = [Result<Data?, Error>]()
    private var cancelled = false

    var source: BrokerHTTPStreamSource {
        BrokerHTTPStreamSource(
            response: BrokerHTTPResponseHead(statusCode: 200, headers: ["content-type": "text/event-stream"]),
            read: { [self] _ in try await next() },
            cancel: { [self] in cancel() }
        )
    }

    var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    func send(_ data: Data) {
        condition.lock()
        values.append(.success(data))
        condition.broadcast()
        condition.unlock()
    }

    func finish() {
        condition.lock()
        values.append(.success(nil))
        condition.broadcast()
        condition.unlock()
    }

    private func next() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { [self] in
                condition.lock()
                while values.isEmpty && !cancelled {
                    condition.wait()
                }
                let result = values.isEmpty
                    ? Result<Data?, Error>.failure(ServiceBrokerHTTPError.cancelled)
                    : values.removeFirst()
                condition.unlock()
                continuation.resume(with: result)
            }
        }
    }

    private func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }
}

private func assertChannelError(
    _ expected: BrokerChannelError,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: @escaping () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected).", file: file, line: line)
    } catch let error as BrokerChannelError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected \(expected), got \(error).", file: file, line: line)
    }
}
