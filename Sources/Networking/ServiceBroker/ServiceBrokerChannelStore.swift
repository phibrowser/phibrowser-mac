// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

actor ServiceBrokerChannelStore {
    private static let maximumQueuedEvents = 128
    /// One `broker.ws.pull` costs a full round trip across the extension bridge,
    /// so a pull drains as much of the queue as these limits allow rather than a
    /// single event. phi-agent emits one frame per model delta, and a per-frame
    /// round trip cannot keep up with a long streamed reply.
    private static let maximumEventsPerPull = 64
    private static let maximumBytesPerPull = 512 * 1024
    /// The queue depth a paused WebSocket read loop resumes at. Halving the
    /// high-water marks keeps a resumed loop from stalling again immediately.
    private static let lowWaterQueuedEvents = maximumQueuedEvents / 2

    typealias HTTPStreamOpener = @Sendable (BrokerHTTPRequest) async throws -> BrokerHTTPStreamSource
    typealias WebSocketOpener = @Sendable (String, [String: String]) async throws -> BrokerWebSocketSource
    typealias PendingPullObserver = @Sendable (String) -> Void
    typealias PullTimeoutSleeper = @Sendable (Duration) async throws -> Void

    private struct PendingHTTPPull {
        let token: UUID
        let continuation: CheckedContinuation<BrokerStreamPullResponse, Never>
        let timeoutTask: Task<Void, Never>
    }

    private struct PendingWebSocketPull {
        let token: UUID
        let continuation: CheckedContinuation<BrokerWebSocketPullResponse, Never>
        let timeoutTask: Task<Void, Never>
    }

    private struct HTTPChannel {
        let owner: BrokerSenderContext
        let source: BrokerHTTPStreamSource
        var queue = [BrokerPullEvent]()
        var queuedBytes = 0
        var nextSequence: UInt64 = 0
        var terminal = false
        var pendingPull: PendingHTTPPull?
        var activityGeneration: UInt64 = 0
        var idleTask: Task<Void, Never>?
        var readTask: Task<Void, Never>?
    }

    private struct WebSocketChannel {
        let owner: BrokerSenderContext
        let source: BrokerWebSocketSource
        var queue = [BrokerWebSocketEvent]()
        var queuedBytes = 0
        var terminal = false
        var pendingPull: PendingWebSocketPull?
        var activityGeneration: UInt64 = 0
        var idleTask: Task<Void, Never>?
        var readTask: Task<Void, Never>?
        /// Set while the read loop is parked at the high-water mark. Resumed by
        /// a pull that drains below the low-water mark, and by every terminal
        /// transition so the loop can observe the channel and exit.
        var readGate: CheckedContinuation<Void, Never>?
    }

    private enum Channel {
        case http(HTTPChannel)
        case webSocket(WebSocketChannel)
    }

    private let configuration: ServiceBrokerChannelConfiguration
    private let httpStreamOpener: HTTPStreamOpener
    private let webSocketOpener: WebSocketOpener
    private let pendingPullObserver: PendingPullObserver
    private let pullTimeoutSleeper: PullTimeoutSleeper
    private let idleTimeoutSleeper: PullTimeoutSleeper
    private var channels = [String: Channel]()

    init(
        socketPath: String,
        limits: ServiceBrokerLimits,
        pullTimeout: Duration = .seconds(25),
        idleTimeout: Duration = .seconds(60)
    ) {
        let configuration = ServiceBrokerChannelConfiguration(
            limits: limits,
            pullTimeout: pullTimeout,
            idleTimeout: idleTimeout
        )
        let client = ServiceBrokerClient(socketPath: socketPath, limits: limits)
        self.configuration = configuration
        pendingPullObserver = { _ in }
        pullTimeoutSleeper = { duration in try await Task.sleep(for: duration) }
        idleTimeoutSleeper = { duration in try await Task.sleep(for: duration) }
        httpStreamOpener = { request in
            let stream = try await client.openStream(request)
            return BrokerHTTPStreamSource(
                response: stream.response,
                read: { maxBytes in try await stream.read(maxBytes: maxBytes) },
                cancel: { stream.cancel() }
            )
        }
        webSocketOpener = { brokerPath, headers in
            let socket = ServiceBrokerWebSocket(
                socketPath: socketPath,
                maximumMessageBytes: configuration.webSocketMessageBytes
            )
            try await socket.connect(brokerPath: brokerPath, headers: headers)
            return socket.source
        }
    }

    init(
        configuration: ServiceBrokerChannelConfiguration,
        httpStreamOpener: @escaping HTTPStreamOpener,
        webSocketOpener: @escaping WebSocketOpener,
        pendingPullObserver: @escaping PendingPullObserver = { _ in },
        pullTimeoutSleeper: @escaping PullTimeoutSleeper = { duration in
            try await Task.sleep(for: duration)
        },
        idleTimeoutSleeper: @escaping PullTimeoutSleeper = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.configuration = configuration
        self.httpStreamOpener = httpStreamOpener
        self.webSocketOpener = webSocketOpener
        self.pendingPullObserver = pendingPullObserver
        self.pullTimeoutSleeper = pullTimeoutSleeper
        self.idleTimeoutSleeper = idleTimeoutSleeper
    }

    func openHTTPStream(
        owner: BrokerSenderContext,
        request: BrokerHTTPRequest
    ) async throws -> BrokerStreamOpenResponse {
        try validateConfiguration()
        let source = try await httpStreamOpener(request)
        let channelID = makeChannelID()
        channels[channelID] = .http(HTTPChannel(owner: owner, source: source))
        touchHTTP(channelID: channelID)

        let readTask = Task { [weak self] in
            guard let self else { return }
            await self.readHTTP(channelID: channelID, source: source)
        }
        guard case .http(var channel) = channels[channelID] else {
            source.cancel()
            throw BrokerChannelError.channelNotFound
        }
        channel.readTask = readTask
        channels[channelID] = .http(channel)

        return BrokerStreamOpenResponse(
            channelID: channelID,
            statusCode: source.response.statusCode,
            headers: source.response.headers
        )
    }

    func pullHTTP(
        owner: BrokerSenderContext,
        channelID: String
    ) async throws -> BrokerStreamPullResponse {
        guard case .http(let owned) = try ownedChannel(owner: owner, channelID: channelID) else {
            throw BrokerChannelError.invalidChannelKind
        }
        guard owned.pendingPull == nil else { throw BrokerChannelError.pullAlreadyPending }
        touchHTTP(channelID: channelID)
        guard case .http(var channel) = channels[channelID] else {
            throw BrokerChannelError.channelNotFound
        }

        guard channel.queue.isEmpty else {
            let event = channel.queue.removeFirst()
            channel.queuedBytes -= event.byteCount
            channels[channelID] = .http(channel)
            if channel.terminal && channel.queue.isEmpty {
                removeChannel(channelID)
            }
            return BrokerStreamPullResponse(event: event)
        }

        return await withCheckedContinuation { continuation in
            let token = UUID()
            let timeout = configuration.pullTimeout
            let sleeper = pullTimeoutSleeper
            let timeoutTask = Task { [weak self] in
                try? await sleeper(timeout)
                guard !Task.isCancelled else { return }
                await self?.timeoutHTTPPull(channelID: channelID, token: token)
            }
            channel.pendingPull = PendingHTTPPull(
                token: token,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            channels[channelID] = .http(channel)
            pendingPullObserver(channelID)
        }
    }

    func openWebSocket(
        owner: BrokerSenderContext,
        service: BrokerService = .phiAgent,
        path: String,
        headers: [String: String]
    ) async throws -> BrokerWebSocketOpenResponse {
        try validateConfiguration()
        guard service != .broker, path.hasPrefix("/"), !path.hasPrefix("//") else {
            throw BrokerChannelError.invalidConfiguration
        }
        let source = try await webSocketOpener("/\(service.rawValue)\(path)", headers)
        let channelID = makeChannelID()
        channels[channelID] = .webSocket(WebSocketChannel(owner: owner, source: source))
        touchWebSocket(channelID: channelID)

        let readTask = Task { [weak self] in
            guard let self else { return }
            await self.readWebSocket(channelID: channelID, source: source)
        }
        guard case .webSocket(var channel) = channels[channelID] else {
            await source.close(code: 1001, reason: "Channel closed during setup.")
            throw BrokerChannelError.channelNotFound
        }
        channel.readTask = readTask
        channels[channelID] = .webSocket(channel)
        return BrokerWebSocketOpenResponse(channelID: channelID)
    }

    func sendWebSocket(
        owner: BrokerSenderContext,
        channelID: String,
        frame: BrokerWebSocketFrame
    ) async throws {
        guard case .webSocket(let channel) = try ownedChannel(owner: owner, channelID: channelID) else {
            throw BrokerChannelError.invalidChannelKind
        }
        guard !channel.terminal else { throw BrokerChannelError.channelNotFound }
        guard frame.data.count <= configuration.webSocketMessageBytes else {
            failWebSocket(
                channelID: channelID,
                code: .protocolError,
                message: "WebSocket message exceeds the negotiated limit."
            )
            throw ServiceBrokerWebSocketError.protocolError
        }
        touchWebSocket(channelID: channelID)
        do {
            try await channel.source.send(frame)
        } catch {
            failWebSocket(channelID: channelID, error: error)
            throw error
        }
    }

    func pullWebSocket(
        owner: BrokerSenderContext,
        channelID: String
    ) async throws -> BrokerWebSocketPullResponse {
        guard case .webSocket(let owned) = try ownedChannel(owner: owner, channelID: channelID) else {
            throw BrokerChannelError.invalidChannelKind
        }
        guard owned.pendingPull == nil else { throw BrokerChannelError.pullAlreadyPending }
        touchWebSocket(channelID: channelID)
        guard case .webSocket(var channel) = channels[channelID] else {
            throw BrokerChannelError.channelNotFound
        }

        guard channel.queue.isEmpty else {
            var events = [BrokerWebSocketEvent]()
            var batchBytes = 0
            while let next = channel.queue.first {
                let nextBytes = next.byteCount
                guard events.isEmpty
                    || (events.count < Self.maximumEventsPerPull
                        && batchBytes + nextBytes <= Self.maximumBytesPerPull) else { break }
                channel.queue.removeFirst()
                channel.queuedBytes -= nextBytes
                batchBytes += nextBytes
                events.append(next)
                if next.isTerminal { break }
            }
            channels[channelID] = .webSocket(channel)
            if channel.terminal && channel.queue.isEmpty {
                removeChannel(channelID)
            } else {
                resumeReadGateIfDrained(channelID: channelID)
            }
            return BrokerWebSocketPullResponse(events: events)
        }

        return await withCheckedContinuation { continuation in
            let token = UUID()
            let timeout = configuration.pullTimeout
            let sleeper = pullTimeoutSleeper
            let timeoutTask = Task { [weak self] in
                try? await sleeper(timeout)
                guard !Task.isCancelled else { return }
                await self?.timeoutWebSocketPull(channelID: channelID, token: token)
            }
            channel.pendingPull = PendingWebSocketPull(
                token: token,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            channels[channelID] = .webSocket(channel)
            pendingPullObserver(channelID)
        }
    }

    func cancelHTTP(
        owner: BrokerSenderContext,
        channelID: String
    ) throws {
        guard case .http = try ownedChannel(owner: owner, channelID: channelID) else {
            throw BrokerChannelError.invalidChannelKind
        }
        guard case .http(let http) = removeChannel(channelID) else {
            throw BrokerChannelError.channelNotFound
        }
        http.source.cancel()
        http.pendingPull?.continuation.resume(returning: BrokerStreamPullResponse(event: .end))
    }

    func closeWebSocket(
        owner: BrokerSenderContext,
        channelID: String,
        code: UInt16?,
        reason: String?
    ) async throws {
        guard case .webSocket = try ownedChannel(owner: owner, channelID: channelID) else {
            throw BrokerChannelError.invalidChannelKind
        }
        guard case .webSocket(let webSocket) = removeChannel(channelID) else {
            throw BrokerChannelError.channelNotFound
        }
        webSocket.pendingPull?.continuation.resume(returning: BrokerWebSocketPullResponse(
            event: .close(code: code, reason: reason)
        ))
        await webSocket.source.close(code: code, reason: reason)
    }

    private func readHTTP(channelID: String, source: BrokerHTTPStreamSource) async {
        do {
            while let data = try await source.read(maxBytes: configuration.bridgeChunkBytes) {
                guard !data.isEmpty else { continue }
                receiveHTTPData(data, channelID: channelID)
                guard channels[channelID] != nil else { return }
            }
            finishHTTP(channelID: channelID, event: .end)
        } catch ServiceBrokerHTTPError.cancelled {
            return
        } catch {
            finishHTTP(
                channelID: channelID,
                event: .failure(code: .upstreamError, message: "Upstream HTTP stream failed.")
            )
        }
    }

    private func receiveHTTPData(_ data: Data, channelID: String) {
        guard case .http(var channel) = channels[channelID], !channel.terminal else { return }
        let event = BrokerPullEvent.data(sequence: channel.nextSequence, data: data)
        channel.nextSequence &+= 1
        if let pending = channel.pendingPull {
            pending.timeoutTask.cancel()
            channel.pendingPull = nil
            channels[channelID] = .http(channel)
            pending.continuation.resume(returning: BrokerStreamPullResponse(event: event))
            touchHTTP(channelID: channelID)
            return
        }
        guard channel.queue.count < Self.maximumQueuedEvents,
              channel.queuedBytes <= configuration.unacknowledgedWindowBytes - data.count else {
            channels[channelID] = .http(channel)
            failHTTPBackpressure(channelID: channelID)
            return
        }
        channel.queue.append(event)
        channel.queuedBytes += data.count
        channels[channelID] = .http(channel)
    }

    private func finishHTTP(channelID: String, event: BrokerPullEvent) {
        guard case .http(var channel) = channels[channelID], !channel.terminal else { return }
        channel.source.cancel()
        channel.terminal = true
        if let pending = channel.pendingPull, channel.queue.isEmpty {
            pending.timeoutTask.cancel()
            channel.pendingPull = nil
            channels[channelID] = .http(channel)
            pending.continuation.resume(returning: BrokerStreamPullResponse(event: event))
            removeChannel(channelID)
            return
        }
        // A terminal event carries no unacknowledged payload and must remain
        // observable even when the data queue is exactly full.
        channel.queue.append(event)
        channels[channelID] = .http(channel)
    }

    private func failHTTPBackpressure(channelID: String) {
        guard case .http(var channel) = channels[channelID], !channel.terminal else { return }
        channel.source.cancel()
        channel.terminal = true
        channel.queue.removeAll(keepingCapacity: false)
        channel.queuedBytes = 0
        let event = BrokerPullEvent.failure(
            code: .flowControlTimeout,
            message: "Channel backpressure limit exceeded."
        )
        if let pending = channel.pendingPull {
            pending.timeoutTask.cancel()
            pending.continuation.resume(returning: BrokerStreamPullResponse(event: event))
            removeChannel(channelID)
        } else {
            channel.queue.append(event)
            channels[channelID] = .http(channel)
        }
    }

    private func readWebSocket(channelID: String, source: BrokerWebSocketSource) async {
        do {
            while true {
                await awaitReadCapacity(channelID: channelID)
                guard isReadable(channelID: channelID) else { return }
                let event = try await source.receive()
                receiveWebSocketEvent(event, channelID: channelID)
                switch event {
                case .close, .failure:
                    return
                case .frame, .timeout:
                    guard channels[channelID] != nil else { return }
                }
            }
        } catch {
            failWebSocket(channelID: channelID, error: error)
        }
    }

    private func receiveWebSocketEvent(_ event: BrokerWebSocketEvent, channelID: String) {
        guard case .webSocket(var channel) = channels[channelID], !channel.terminal else { return }
        let terminal: Bool
        switch event {
        case .close, .failure:
            terminal = true
        case .frame, .timeout:
            terminal = false
        }
        if let pending = channel.pendingPull {
            channel.terminal = terminal
            pending.timeoutTask.cancel()
            channel.pendingPull = nil
            channels[channelID] = .webSocket(channel)
            pending.continuation.resume(returning: BrokerWebSocketPullResponse(event: event))
            if terminal { removeChannel(channelID) } else { touchWebSocket(channelID: channelID) }
            return
        }
        // The event was already read off the socket, so it is always enqueued —
        // it may push the queue past the high-water mark. `awaitReadCapacity`
        // then parks the read loop until a pull drains the queue, which lets the
        // kernel socket buffer, and in turn the broker, feel the backpressure.
        channel.terminal = terminal
        channel.queue.append(event)
        channel.queuedBytes += event.byteCount
        channels[channelID] = .webSocket(channel)
    }

    /// Parks the WebSocket read loop while the channel sits at or above its
    /// high-water mark. Only the channel's own read loop calls this, so at most
    /// one continuation is ever stored.
    private func awaitReadCapacity(channelID: String) async {
        guard case .webSocket(let channel) = channels[channelID],
              !channel.terminal,
              isAtHighWater(channel) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard case .webSocket(var stored) = channels[channelID], !stored.terminal else {
                continuation.resume()
                return
            }
            stored.readGate = continuation
            channels[channelID] = .webSocket(stored)
        }
    }

    /// A parked read loop is released by expiry, failure and removal as well as
    /// by drainage, so it must re-check the channel before reading again.
    private func isReadable(channelID: String) -> Bool {
        guard case .webSocket(let channel) = channels[channelID] else { return false }
        return !channel.terminal
    }

    private func isAtHighWater(_ channel: WebSocketChannel) -> Bool {
        channel.queue.count >= Self.maximumQueuedEvents
            || channel.queuedBytes >= configuration.unacknowledgedWindowBytes
    }

    private func resumeReadGateIfDrained(channelID: String) {
        guard case .webSocket(var channel) = channels[channelID],
              channel.readGate != nil,
              channel.queue.count <= Self.lowWaterQueuedEvents,
              channel.queuedBytes <= configuration.unacknowledgedWindowBytes / 2 else { return }
        let gate = channel.readGate
        channel.readGate = nil
        channels[channelID] = .webSocket(channel)
        gate?.resume()
    }

    private func failWebSocket(channelID: String, error: Error) {
        let code: NativeBrokerErrorCode
        if let webSocketError = error as? ServiceBrokerWebSocketError,
           webSocketError == .protocolError {
            code = .protocolError
        } else {
            code = .upstreamError
        }
        let message = code == .protocolError ? "WebSocket protocol error." : "Upstream WebSocket failed."
        failWebSocket(channelID: channelID, code: code, message: message)
    }

    private func failWebSocket(channelID: String, code: NativeBrokerErrorCode, message: String) {
        guard case .webSocket(var channel) = channels[channelID], !channel.terminal else { return }
        channel.terminal = true
        channel.queue.removeAll(keepingCapacity: false)
        channel.queuedBytes = 0
        // Take the gate out of the stored channel before any removal so it is
        // resumed exactly once, whichever branch runs.
        let gate = channel.readGate
        channel.readGate = nil
        let pending = channel.pendingPull
        channel.pendingPull = nil
        let event = BrokerWebSocketEvent.failure(code: code, message: message)
        let source = channel.source
        let closeCode: UInt16 = code == .protocolError ? 1002 : 1011
        Task { await source.close(code: closeCode, reason: message) }
        if let pending {
            channels[channelID] = .webSocket(channel)
            pending.timeoutTask.cancel()
            pending.continuation.resume(returning: BrokerWebSocketPullResponse(event: event))
            removeChannel(channelID)
        } else {
            channel.queue.append(event)
            channels[channelID] = .webSocket(channel)
        }
        gate?.resume()
    }

    private func timeoutHTTPPull(channelID: String, token: UUID) {
        guard case .http(var channel) = channels[channelID],
              let pending = channel.pendingPull,
              pending.token == token else { return }
        channel.pendingPull = nil
        channels[channelID] = .http(channel)
        pending.continuation.resume(returning: BrokerStreamPullResponse(event: .timeout))
        touchHTTP(channelID: channelID)
    }

    private func timeoutWebSocketPull(channelID: String, token: UUID) {
        guard case .webSocket(var channel) = channels[channelID],
              let pending = channel.pendingPull,
              pending.token == token else { return }
        channel.pendingPull = nil
        channels[channelID] = .webSocket(channel)
        pending.continuation.resume(returning: BrokerWebSocketPullResponse(event: .timeout))
        touchWebSocket(channelID: channelID)
    }

    private func touchHTTP(channelID: String) {
        guard case .http(var channel) = channels[channelID] else { return }
        channel.activityGeneration &+= 1
        let generation = channel.activityGeneration
        channel.idleTask?.cancel()
        let timeout = configuration.idleTimeout
        let sleeper = idleTimeoutSleeper
        channel.idleTask = Task { [weak self] in
            try? await sleeper(timeout)
            guard !Task.isCancelled else { return }
            await self?.expireHTTP(channelID: channelID, generation: generation)
        }
        channels[channelID] = .http(channel)
    }

    private func touchWebSocket(channelID: String) {
        guard case .webSocket(var channel) = channels[channelID] else { return }
        channel.activityGeneration &+= 1
        let generation = channel.activityGeneration
        channel.idleTask?.cancel()
        let timeout = configuration.idleTimeout
        let sleeper = idleTimeoutSleeper
        channel.idleTask = Task { [weak self] in
            try? await sleeper(timeout)
            guard !Task.isCancelled else { return }
            await self?.expireWebSocket(channelID: channelID, generation: generation)
        }
        channels[channelID] = .webSocket(channel)
    }

    private func expireHTTP(channelID: String, generation: UInt64) {
        guard case .http(let channel) = channels[channelID],
              channel.activityGeneration == generation else { return }
        channel.source.cancel()
        channel.pendingPull?.continuation.resume(returning: BrokerStreamPullResponse(
            event: .failure(code: .channelNotFound, message: "Channel expired while idle.")
        ))
        removeChannel(channelID)
    }

    private func expireWebSocket(channelID: String, generation: UInt64) {
        guard case .webSocket(let channel) = channels[channelID],
              channel.activityGeneration == generation else { return }
        let source = channel.source
        Task { await source.close(code: 1001, reason: "Channel expired while idle.") }
        channel.pendingPull?.continuation.resume(returning: BrokerWebSocketPullResponse(
            event: .failure(code: .channelNotFound, message: "Channel expired while idle.")
        ))
        removeChannel(channelID)
    }

    private func ownedChannel(owner: BrokerSenderContext, channelID: String) throws -> Channel {
        guard let channel = channels[channelID] else { throw BrokerChannelError.channelNotFound }
        let channelOwner: BrokerSenderContext
        switch channel {
        case .http(let http): channelOwner = http.owner
        case .webSocket(let webSocket): channelOwner = webSocket.owner
        }
        guard channelOwner == owner else { throw BrokerChannelError.ownerMismatch }
        return channel
    }

    @discardableResult
    private func removeChannel(_ channelID: String) -> Channel? {
        guard let channel = channels.removeValue(forKey: channelID) else { return nil }
        switch channel {
        case .http(let http):
            http.readTask?.cancel()
            http.idleTask?.cancel()
            http.pendingPull?.timeoutTask.cancel()
            return channel
        case .webSocket(var webSocket):
            webSocket.readTask?.cancel()
            webSocket.idleTask?.cancel()
            webSocket.pendingPull?.timeoutTask.cancel()
            // Cancelling the read task does not resume a parked continuation, so
            // release the gate here: expiry, close and failure all remove the
            // channel, and the released loop then observes it is gone and exits.
            let gate = webSocket.readGate
            webSocket.readGate = nil
            gate?.resume()
            return .webSocket(webSocket)
        }
    }

    private func validateConfiguration() throws {
        guard configuration.bridgeChunkBytes > 0,
              configuration.webSocketMessageBytes > 0,
              configuration.unacknowledgedWindowBytes > 0,
              configuration.pullTimeout > .zero,
              configuration.idleTimeout > .zero else {
            throw BrokerChannelError.invalidConfiguration
        }
    }

    private func makeChannelID() -> String {
        var channelID: String
        repeat { channelID = UUID().uuidString.lowercased() } while channels[channelID] != nil
        return channelID
    }
}

private extension BrokerPullEvent {
    var byteCount: Int {
        if case .data(_, let data) = self { return data.count }
        return 0
    }
}

private extension BrokerWebSocketEvent {
    var byteCount: Int {
        if case .frame(_, let frame) = self { return frame.data.count }
        return 0
    }

    var isTerminal: Bool {
        switch self {
        case .close, .failure: true
        case .frame, .timeout: false
        }
    }
}
