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

        try await store.cancelHTTP(owner: owner, channelID: opened.channelID)
    }

    func testOnlyOnePullMayWaitPerChannel() async throws {
        let stream = FakeBrokerHTTPStream()
        let pendingPull = AsyncSignal()
        let store = makeStore(httpStream: stream, pullTimeout: .seconds(1), pendingPull: pendingPull)
        let opened = try await store.openHTTPStream(owner: owner, request: request())
        let firstPull = Task { try await store.pullHTTP(owner: owner, channelID: opened.channelID) }
        await pendingPull.wait()

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

        let signalledStream = FakeBrokerHTTPStream()
        let pendingPull = AsyncSignal()
        let signalledStore = makeStore(httpStream: signalledStream, pendingPull: pendingPull)
        let signalledOpened = try await signalledStore.openHTTPStream(owner: owner, request: request())
        let waitingPull = Task { try await signalledStore.pullHTTP(owner: owner, channelID: signalledOpened.channelID) }
        await pendingPull.wait()
        signalledStream.send(Data("ready".utf8))

        let response = try await waitingPull.value
        XCTAssertEqual(response.event, .data(sequence: 0, data: Data("ready".utf8)))
        try await signalledStore.cancelHTTP(owner: owner, channelID: signalledOpened.channelID)
        try await store.cancelHTTP(owner: owner, channelID: opened.channelID)
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
        let pendingPull = AsyncSignal()
        let store = makeStore(httpStream: stream, pullTimeout: .seconds(1), pendingPull: pendingPull)
        let opened = try await store.openHTTPStream(owner: owner, request: request())
        let pull = Task { try await store.pullHTTP(owner: owner, channelID: opened.channelID) }
        await pendingPull.wait()

        try await store.cancelHTTP(owner: owner, channelID: opened.channelID)

        let response = try await pull.value
        XCTAssertEqual(response.event, .end)
        XCTAssertTrue(stream.isCancelled)
    }

    func testTimeoutThenLocalCloseDoesNotResumePullTwice() async throws {
        let stream = FakeBrokerHTTPStream()
        let pendingPull = AsyncSignal()
        let timeoutGate = AsyncGate()
        let store = makeStore(
            httpStream: stream,
            pendingPull: pendingPull,
            pullTimeoutSleeper: { _ in await timeoutGate.enter() }
        )
        let opened = try await store.openHTTPStream(owner: owner, request: request())
        let pull = Task { try await store.pullHTTP(owner: owner, channelID: opened.channelID) }
        await pendingPull.wait()
        await timeoutGate.waitUntilEntered()

        await timeoutGate.release()
        let result = try await pull.value
        XCTAssertEqual(result.event, .timeout)
        try await store.cancelHTTP(owner: owner, channelID: opened.channelID)
        XCTAssertTrue(stream.isCancelled)
    }

    func testReaderThenLocalCloseDoesNotResumePullTwice() async throws {
        let stream = FakeBrokerHTTPStream()
        let pendingPull = AsyncSignal()
        let store = makeStore(httpStream: stream, pendingPull: pendingPull)
        let opened = try await store.openHTTPStream(owner: owner, request: request())
        let pull = Task { try await store.pullHTTP(owner: owner, channelID: opened.channelID) }
        await pendingPull.wait()

        stream.send(Data("reader wins".utf8))
        let result = try await pull.value
        XCTAssertEqual(result.event, .data(sequence: 0, data: Data("reader wins".utf8)))
        try await store.cancelHTTP(owner: owner, channelID: opened.channelID)
        XCTAssertTrue(stream.isCancelled)
    }

    func testLocalCloseWinsAgainstReadyTimeoutWithoutDoubleResume() async throws {
        let stream = FakeBrokerHTTPStream()
        let pendingPull = AsyncSignal()
        let timeoutGate = AsyncGate()
        let store = makeStore(
            httpStream: stream,
            pendingPull: pendingPull,
            pullTimeoutSleeper: { _ in await timeoutGate.enter() }
        )
        let opened = try await store.openHTTPStream(owner: owner, request: request())
        let pull = Task { try await store.pullHTTP(owner: owner, channelID: opened.channelID) }
        await pendingPull.wait()
        await timeoutGate.waitUntilEntered()

        try await store.cancelHTTP(owner: owner, channelID: opened.channelID)
        let result = try await pull.value
        XCTAssertEqual(result.event, .end)
        await timeoutGate.release()
        await assertChannelError(.channelNotFound) {
            _ = try await store.pullHTTP(owner: self.owner, channelID: opened.channelID)
        }
    }

    func testLocalCloseWinsAgainstReadyReaderWithoutDoubleResume() async throws {
        let deliveryGate = AsyncGate()
        let stream = FakeBrokerHTTPStream(deliveryGate: deliveryGate)
        let pendingPull = AsyncSignal()
        let store = makeStore(httpStream: stream, pendingPull: pendingPull)
        let opened = try await store.openHTTPStream(owner: owner, request: request())
        let pull = Task { try await store.pullHTTP(owner: owner, channelID: opened.channelID) }
        await pendingPull.wait()
        stream.send(Data("stale reader".utf8))
        await deliveryGate.waitUntilEntered()

        try await store.cancelHTTP(owner: owner, channelID: opened.channelID)
        let result = try await pull.value
        XCTAssertEqual(result.event, .end)
        await deliveryGate.release()
        await assertChannelError(.channelNotFound) {
            _ = try await store.pullHTTP(owner: self.owner, channelID: opened.channelID)
        }
    }

    func testLocalCloseWinsAgainstReadyExpiryWithoutDoubleResume() async throws {
        let stream = FakeBrokerHTTPStream()
        let pendingPull = AsyncSignal()
        let idleGate = AsyncGate()
        let store = makeStore(
            httpStream: stream,
            pendingPull: pendingPull,
            idleTimeoutSleeper: { _ in await idleGate.enter() }
        )
        let opened = try await store.openHTTPStream(owner: owner, request: request())
        await idleGate.waitUntilEntered()
        let pull = Task { try await store.pullHTTP(owner: owner, channelID: opened.channelID) }
        await pendingPull.wait()
        await idleGate.waitUntilEntered(2)

        try await store.cancelHTTP(owner: owner, channelID: opened.channelID)
        let result = try await pull.value
        XCTAssertEqual(result.event, .end)
        await idleGate.release()
        await assertChannelError(.channelNotFound) {
            _ = try await store.pullHTTP(owner: self.owner, channelID: opened.channelID)
        }
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
        await stream.waitUntilCancelled()

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
        socket.receive(.frame(
            sequence: 0, BrokerWebSocketFrame(kind: .binary, data: Data([1, 2, 3]))))
        socket.receive(.close(code: 1000, reason: "done"))

        let pulled = try await drainUntilTerminal(store, channelID: opened.channelID)

        XCTAssertEqual(socket.sentFrames, [outgoing])
        XCTAssertEqual(pulled, [
            .frame(sequence: 0, BrokerWebSocketFrame(kind: .binary, data: Data([1, 2, 3]))),
            .close(code: 1000, reason: "done"),
        ])
    }

    func testWebSocketTerminalCloseSurvivesAFullDataQueue() async throws {
        let socket = FakeBrokerWebSocket()
        let store = ServiceBrokerChannelStore(
            configuration: ServiceBrokerChannelConfiguration(
                bridgeChunkBytes: 64,
                webSocketMessageBytes: 1_024,
                unacknowledgedWindowBytes: 4_096,
                pullTimeout: .seconds(1),
                idleTimeout: .seconds(1)
            ),
            httpStreamOpener: { _ in throw BrokerChannelError.invalidChannelKind },
            webSocketOpener: { _, _ in socket.source }
        )
        let opened = try await store.openWebSocket(
            owner: owner, path: "/ws/phi-agent/execute", headers: [:])
        for sequence in 0..<128 {
            socket.receive(.frame(
                sequence: UInt64(sequence),
                BrokerWebSocketFrame(kind: .text, data: Data([UInt8(sequence % 255)]))
            ))
        }
        socket.receive(.close(code: 1000, reason: "done"))

        let drained = try await drainUntilTerminal(store, channelID: opened.channelID)

        XCTAssertEqual(drained.count, 129)
        XCTAssertEqual(drained.last, .close(code: 1000, reason: "done"))
    }

    func testWebSocketFramesHaveChannelOwnedSequenceNumbers() async throws {
        let socket = FakeBrokerWebSocket()
        let store = makeWebSocketStore(socket: socket)
        let opened = try await store.openWebSocket(
            owner: owner, path: "/ws/phi-agent/execute", headers: [:])
        socket.receive(.frame(
            sequence: 0, BrokerWebSocketFrame(kind: .text, data: Data("one".utf8))))
        socket.receive(.frame(
            sequence: 1, BrokerWebSocketFrame(kind: .text, data: Data("two".utf8))))

        let events = try await collectEvents(store, channelID: opened.channelID, count: 2)

        XCTAssertEqual(events, [
            .frame(sequence: 0, BrokerWebSocketFrame(kind: .text, data: Data("one".utf8))),
            .frame(sequence: 1, BrokerWebSocketFrame(kind: .text, data: Data("two".utf8))),
        ])
        try await store.closeWebSocket(
            owner: owner, channelID: opened.channelID, code: 1000, reason: nil)
    }

    func testKindSpecificCloseOperationsRejectTheWrongChannelKind() async throws {
        let stream = FakeBrokerHTTPStream()
        let socket = FakeBrokerWebSocket()
        let store = ServiceBrokerChannelStore(
            configuration: ServiceBrokerChannelConfiguration(
                bridgeChunkBytes: 64,
                webSocketMessageBytes: 1_024,
                unacknowledgedWindowBytes: 1_024,
                pullTimeout: .seconds(1),
                idleTimeout: .seconds(1)
            ),
            httpStreamOpener: { _ in stream.source },
            webSocketOpener: { _, _ in socket.source }
        )
        let http = try await store.openHTTPStream(owner: owner, request: request())
        let webSocket = try await store.openWebSocket(
            owner: owner, path: "/ws/phi-agent/execute", headers: [:])

        await assertChannelError(.invalidChannelKind) {
            try await store.closeWebSocket(
                owner: self.owner, channelID: http.channelID, code: 1000, reason: nil)
        }
        await assertChannelError(.invalidChannelKind) {
            try await store.cancelHTTP(owner: self.owner, channelID: webSocket.channelID)
        }
        XCTAssertFalse(stream.isCancelled)
        XCTAssertFalse(socket.isClosed)
        try await store.cancelHTTP(owner: owner, channelID: http.channelID)
        try await store.closeWebSocket(
            owner: owner, channelID: webSocket.channelID, code: 1000, reason: nil)
    }

    func testLocalWebSocketCloseUnblocksPendingPullExactlyOnce() async throws {
        let socket = FakeBrokerWebSocket()
        let pendingPull = AsyncSignal()
        let store = makeWebSocketStore(socket: socket, pendingPull: pendingPull)
        let opened = try await store.openWebSocket(owner: owner, path: "/ws/phi-agent/execute", headers: [:])
        let pull = Task { try await store.pullWebSocket(owner: owner, channelID: opened.channelID) }
        await pendingPull.wait()

        try await store.closeWebSocket(
            owner: owner, channelID: opened.channelID, code: 1000, reason: "done")

        let result = try await pull.value
        XCTAssertEqual(result.events, [.close(code: 1000, reason: "done")])
        XCTAssertTrue(socket.isClosed)
        await assertChannelError(.channelNotFound) {
            _ = try await store.pullWebSocket(owner: self.owner, channelID: opened.channelID)
        }
    }

    func testWebSocketCloseRemovesChannelBeforeAwaitingUpstreamClose() async throws {
        let closeGate = AsyncGate()
        let socket = FakeBrokerWebSocket(closeGate: closeGate)
        let store = makeWebSocketStore(socket: socket)
        let opened = try await store.openWebSocket(owner: owner, path: "/ws/phi-agent/execute", headers: [:])
        let close = Task {
            try await store.closeWebSocket(
                owner: owner, channelID: opened.channelID, code: 1000, reason: nil)
        }
        await closeGate.waitUntilEntered()

        await assertChannelError(.channelNotFound) {
            _ = try await store.pullWebSocket(owner: self.owner, channelID: opened.channelID)
        }

        await closeGate.release()
        try await close.value
    }

    func testWebSocketIdleExpiryRemovesChannelState() async throws {
        let idleGate = AsyncGate()
        let socket = FakeBrokerWebSocket()
        let store = makeWebSocketStore(
            socket: socket,
            idleTimeoutSleeper: { _ in await idleGate.enter() }
        )
        let opened = try await store.openWebSocket(
            owner: owner, path: "/ws/phi-agent/execute", headers: [:])
        await idleGate.waitUntilEntered()

        await idleGate.release()
        await socket.waitUntilClosed()

        XCTAssertTrue(socket.isClosed)
        await assertChannelError(.channelNotFound) {
            _ = try await store.pullWebSocket(owner: self.owner, channelID: opened.channelID)
        }
    }

    func testWebSocketPullDrainsQueuedEventsAsOneBatch() async throws {
        let socket = FakeBrokerWebSocket()
        let store = makeWebSocketStore(socket: socket)
        let opened = try await store.openWebSocket(
            owner: owner, path: "/ws/phi-agent/execute", headers: [:])
        let queued = (0..<5).map { textFrame(sequence: UInt64($0), body: "delta-\($0)") }
        queued.forEach { socket.receive($0) }
        await socket.waitUntilReceiveCalls(queued.count + 1)

        let pulled = try await store.pullWebSocket(owner: owner, channelID: opened.channelID)

        XCTAssertEqual(pulled.events, queued)
        try await store.closeWebSocket(
            owner: owner, channelID: opened.channelID, code: 1000, reason: nil)
    }

    func testWebSocketBatchStopsAtThePerPullEventLimit() async throws {
        let socket = FakeBrokerWebSocket()
        let store = makeWebSocketStore(socket: socket, unacknowledgedWindowBytes: 64 * 1024)
        let opened = try await store.openWebSocket(
            owner: owner, path: "/ws/phi-agent/execute", headers: [:])
        let queued = (0..<70).map { textFrame(sequence: UInt64($0), body: "x") }
        queued.forEach { socket.receive($0) }
        await socket.waitUntilReceiveCalls(queued.count + 1)

        let first = try await store.pullWebSocket(owner: owner, channelID: opened.channelID)
        let second = try await store.pullWebSocket(owner: owner, channelID: opened.channelID)

        XCTAssertEqual(first.events, Array(queued[0..<64]))
        XCTAssertEqual(second.events, Array(queued[64...]))
        try await store.closeWebSocket(
            owner: owner, channelID: opened.channelID, code: 1000, reason: nil)
    }

    func testWebSocketBatchStopsAtThePerPullByteLimit() async throws {
        let socket = FakeBrokerWebSocket()
        let store = makeWebSocketStore(
            socket: socket,
            webSocketMessageBytes: 1024 * 1024,
            unacknowledgedWindowBytes: 4 * 1024 * 1024
        )
        let opened = try await store.openWebSocket(
            owner: owner, path: "/ws/phi-agent/execute", headers: [:])
        let queued = (0..<3).map {
            BrokerWebSocketEvent.frame(
                sequence: UInt64($0),
                BrokerWebSocketFrame(kind: .binary, data: Data(repeating: UInt8($0), count: 200 * 1024))
            )
        }
        queued.forEach { socket.receive($0) }
        await socket.waitUntilReceiveCalls(queued.count + 1)

        let first = try await store.pullWebSocket(owner: owner, channelID: opened.channelID)
        let second = try await store.pullWebSocket(owner: owner, channelID: opened.channelID)

        XCTAssertEqual(first.events, Array(queued[0..<2]))
        XCTAssertEqual(second.events, Array(queued[2...]))
        try await store.closeWebSocket(
            owner: owner, channelID: opened.channelID, code: 1000, reason: nil)
    }

    func testWebSocketBatchEndsAtATerminalEvent() async throws {
        let socket = FakeBrokerWebSocket()
        let store = makeWebSocketStore(socket: socket)
        let opened = try await store.openWebSocket(
            owner: owner, path: "/ws/phi-agent/execute", headers: [:])
        let queued = (0..<3).map { textFrame(sequence: UInt64($0), body: "delta-\($0)") }
            + [.close(code: 1000, reason: "done")]
        queued.forEach { socket.receive($0) }
        await socket.waitUntilReceiveCalls(queued.count)
        try await Task.sleep(for: .milliseconds(50))

        let pulled = try await store.pullWebSocket(owner: owner, channelID: opened.channelID)

        XCTAssertEqual(pulled.events, queued)
        await assertChannelError(.channelNotFound) {
            _ = try await store.pullWebSocket(owner: self.owner, channelID: opened.channelID)
        }
    }

    func testWebSocketPullOnAnEmptyQueueReturnsASingleEvent() async throws {
        let socket = FakeBrokerWebSocket()
        let pendingPull = AsyncSignal()
        let store = makeWebSocketStore(socket: socket, pendingPull: pendingPull)
        let opened = try await store.openWebSocket(
            owner: owner, path: "/ws/phi-agent/execute", headers: [:])
        let pull = Task { try await store.pullWebSocket(owner: owner, channelID: opened.channelID) }
        await pendingPull.wait()
        socket.receive(textFrame(sequence: 0, body: "one"))
        socket.receive(textFrame(sequence: 1, body: "two"))

        let result = try await pull.value

        XCTAssertEqual(result.events, [textFrame(sequence: 0, body: "one")])
        try await store.closeWebSocket(
            owner: owner, channelID: opened.channelID, code: 1000, reason: nil)
    }

    func testWebSocketHighWaterPausesReadsInsteadOfFailingTheChannel() async throws {
        let socket = FakeBrokerWebSocket()
        let store = makeWebSocketStore(socket: socket, unacknowledgedWindowBytes: 64 * 1024)
        let opened = try await store.openWebSocket(
            owner: owner, path: "/ws/phi-agent/execute", headers: [:])
        let queued = (0..<200).map { textFrame(sequence: UInt64($0), body: "x") }
        queued.forEach { socket.receive($0) }

        await socket.waitUntilReceiveCalls(128)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(socket.receiveCallCount, 128)
        XCTAssertFalse(socket.isClosed)

        let first = try await store.pullWebSocket(owner: owner, channelID: opened.channelID)
        XCTAssertEqual(first.events, Array(queued[0..<64]))

        await socket.waitUntilReceiveCalls(192)
        XCTAssertFalse(socket.isClosed)
        try await store.closeWebSocket(
            owner: owner, channelID: opened.channelID, code: 1000, reason: nil)
    }

    func testWebSocketIdleExpiryReleasesAPausedReadLoop() async throws {
        let idleGate = AsyncGate()
        let socket = FakeBrokerWebSocket()
        let store = makeWebSocketStore(
            socket: socket,
            unacknowledgedWindowBytes: 64 * 1024,
            idleTimeoutSleeper: { _ in await idleGate.enter() }
        )
        let opened = try await store.openWebSocket(
            owner: owner, path: "/ws/phi-agent/execute", headers: [:])
        (0..<200).forEach { socket.receive(textFrame(sequence: UInt64($0), body: "x")) }
        await socket.waitUntilReceiveCalls(128)
        await idleGate.waitUntilEntered()
        XCTAssertFalse(socket.isClosed)

        await idleGate.release()
        await socket.waitUntilClosed()

        await assertChannelError(.channelNotFound) {
            _ = try await store.pullWebSocket(owner: self.owner, channelID: opened.channelID)
        }
    }

    private func request() -> BrokerHTTPRequest {
        BrokerHTTPRequest(service: .phiAgent, path: "/stream")
    }

    private func textFrame(sequence: UInt64, body: String) -> BrokerWebSocketEvent {
        .frame(sequence: sequence, BrokerWebSocketFrame(kind: .text, data: Data(body.utf8)))
    }

    /// Pulls until a terminal event arrives and returns every event in order.
    /// A batch may only end with a terminal event, never carry one in the middle.
    private func drainUntilTerminal(
        _ store: ServiceBrokerChannelStore,
        channelID: String,
        maximumPulls: Int = 64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [BrokerWebSocketEvent] {
        var collected = [BrokerWebSocketEvent]()
        for _ in 0..<maximumPulls {
            let batch = try await store.pullWebSocket(owner: owner, channelID: channelID).events
            XCTAssertFalse(batch.isEmpty, "A pull must return at least one event.", file: file, line: line)
            XCTAssertFalse(
                batch.dropLast().contains(where: \.isTerminal),
                "A batch must stop at its terminal event.",
                file: file,
                line: line
            )
            collected.append(contentsOf: batch)
            if batch.last?.isTerminal == true { return collected }
        }
        XCTFail("No terminal event after \(maximumPulls) pulls.", file: file, line: line)
        return collected
    }

    private func collectEvents(
        _ store: ServiceBrokerChannelStore,
        channelID: String,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [BrokerWebSocketEvent] {
        var collected = [BrokerWebSocketEvent]()
        while collected.count < count {
            let batch = try await store.pullWebSocket(owner: owner, channelID: channelID).events
            XCTAssertFalse(batch.isEmpty, "A pull must return at least one event.", file: file, line: line)
            collected.append(contentsOf: batch)
        }
        return collected
    }

    private func makeStore(
        httpStream: FakeBrokerHTTPStream,
        pullTimeout: Duration = .seconds(1),
        idleTimeout: Duration = .seconds(1),
        unacknowledgedWindowBytes: Int = 1_024,
        pendingPull: AsyncSignal? = nil,
        pullTimeoutSleeper: @escaping ServiceBrokerChannelStore.PullTimeoutSleeper = { duration in
            try await Task.sleep(for: duration)
        },
        idleTimeoutSleeper: @escaping ServiceBrokerChannelStore.PullTimeoutSleeper = { duration in
            try await Task.sleep(for: duration)
        }
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
            webSocketOpener: { _, _ in throw BrokerChannelError.invalidChannelKind },
            pendingPullObserver: { _ in pendingPull?.signal() },
            pullTimeoutSleeper: pullTimeoutSleeper,
            idleTimeoutSleeper: idleTimeoutSleeper
        )
    }

    private func makeWebSocketStore(
        socket: FakeBrokerWebSocket,
        webSocketMessageBytes: Int = 1_024,
        unacknowledgedWindowBytes: Int = 1_024,
        pendingPull: AsyncSignal? = nil,
        idleTimeoutSleeper: @escaping ServiceBrokerChannelStore.PullTimeoutSleeper = { duration in
            try await Task.sleep(for: duration)
        }
    ) -> ServiceBrokerChannelStore {
        ServiceBrokerChannelStore(
            configuration: ServiceBrokerChannelConfiguration(
                bridgeChunkBytes: 64,
                webSocketMessageBytes: webSocketMessageBytes,
                unacknowledgedWindowBytes: unacknowledgedWindowBytes,
                pullTimeout: .seconds(1),
                idleTimeout: .seconds(1)
            ),
            httpStreamOpener: { _ in throw BrokerChannelError.invalidChannelKind },
            webSocketOpener: { _, _ in socket.source },
            pendingPullObserver: { _ in pendingPull?.signal() },
            idleTimeoutSleeper: idleTimeoutSleeper
        )
    }
}

private final class FakeBrokerWebSocket: @unchecked Sendable {
    private let condition = NSCondition()
    private var incoming = [Result<BrokerWebSocketEvent, Error>]()
    private var outgoing = [BrokerWebSocketFrame]()
    private var closed = false
    private var receiveCalls = 0
    private let closeGate: AsyncGate?

    init(closeGate: AsyncGate? = nil) {
        self.closeGate = closeGate
    }

    var source: BrokerWebSocketSource {
        BrokerWebSocketSource(
            send: { [self] frame in record(frame) },
            receive: { [self] in try await next() },
            close: { [self] _, _ in
                if let closeGate { await closeGate.enter() }
                closeNow()
            }
        )
    }

    var sentFrames: [BrokerWebSocketFrame] {
        condition.lock()
        defer { condition.unlock() }
        return outgoing
    }

    var isClosed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed
    }

    /// How many times the channel store's read loop has asked for a frame. The
    /// counter is raised before the call can return, so observing call `n + 1`
    /// proves the first `n` events were already handed to the store.
    var receiveCallCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return receiveCalls
    }

    func waitUntilClosed() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                condition.lock()
                while !closed { condition.wait() }
                condition.unlock()
                continuation.resume()
            }
        }
    }

    func waitUntilReceiveCalls(_ count: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                condition.lock()
                while receiveCalls < count { condition.wait() }
                condition.unlock()
                continuation.resume()
            }
        }
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
                receiveCalls += 1
                condition.broadcast()
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
    private let deliveryGate: AsyncGate?

    init(deliveryGate: AsyncGate? = nil) {
        self.deliveryGate = deliveryGate
    }

    var source: BrokerHTTPStreamSource {
        BrokerHTTPStreamSource(
            response: BrokerHTTPResponseHead(
                statusCode: 200,
                headers: [BrokerHTTPHeader(name: "content-type", value: "text/event-stream")]
            ),
            read: { [self] _ in try await next() },
            cancel: { [self] in cancel() }
        )
    }

    var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    func waitUntilCancelled() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                condition.lock()
                while !cancelled { condition.wait() }
                condition.unlock()
                continuation.resume()
            }
        }
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
        let value = try await withCheckedThrowingContinuation { continuation in
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
        if value != nil, let deliveryGate { await deliveryGate.enter() }
        return value
    }

    private func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class AsyncSignal: @unchecked Sendable {
    private let condition = NSCondition()
    private var signalled = false

    func signal() {
        condition.lock()
        signalled = true
        condition.broadcast()
        condition.unlock()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                condition.lock()
                while !signalled { condition.wait() }
                condition.unlock()
                continuation.resume()
            }
        }
    }
}

private actor AsyncGate {
    private var enteredCount = 0
    private var released = false
    private var enteredWaiters = [(count: Int, continuation: CheckedContinuation<Void, Never>)]()
    private var releaseWaiters = [CheckedContinuation<Void, Never>]()

    func enter() async {
        enteredCount += 1
        let ready = enteredWaiters.filter { $0.count <= enteredCount }
        enteredWaiters.removeAll { $0.count <= enteredCount }
        ready.forEach { $0.continuation.resume() }
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered(_ count: Int = 1) async {
        if enteredCount >= count { return }
        await withCheckedContinuation { enteredWaiters.append((count, $0)) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private extension BrokerWebSocketEvent {
    var isTerminal: Bool {
        switch self {
        case .close, .failure: true
        case .frame, .timeout: false
        }
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
