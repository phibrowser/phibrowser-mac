import Foundation
import XCTest
@testable import Phi

final class ServiceBrokerExtensionProtocolTests: XCTestCase {
    private let allowedSender = "fenmfiepnpdlhplemgijlimpbebebljo"

    func testAcceptsOnlyPinnedCanarySidecarSenderAndPinsServiceIdentity() async throws {
        let recorder = BrokerRequestRecorder()
        let handler = makeHandler(recorder: recorder)

        let reply = await handler.handle(
            type: "broker.http.request",
            payload: #"{"path":"/api/v1/chats","method":"post","headers":{"Authorization":"Bearer token","x-phi-extension-id":"attacker"},"bodyBase64":"aGk="}"#,
            senderID: allowedSender
        )

        XCTAssertNil(reply.error)
        let result = try successResult(reply)
        XCTAssertEqual(result["status"] as? Int, 401)
        XCTAssertEqual(result["bodyBase64"] as? String, "e30=")
        let recordedRequest = await recorder.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.service, .phiAgent)
        XCTAssertEqual(request.path, "/api/v1/chats")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.body, Data("hi".utf8))
        XCTAssertEqual(request.headers["Authorization"], "Bearer token")
        XCTAssertNil(request.headers["x-phi-extension-id"])
        XCTAssertEqual(request.headers["X-Phi-Extension-ID"], allowedSender)
        XCTAssertEqual(ServiceBrokerExtensionProtocol.allowedCanarySidecarExtensionID, allowedSender)
    }

    func testRejectsEveryNonSidecarSenderBeforeTransportAccess() async {
        let recorder = BrokerRequestRecorder()
        let handler = makeHandler(recorder: recorder)

        for sender in ["", "cdp", "debug-extension", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                       allowedSender.uppercased()] {
            let reply = await handler.handle(
                type: "broker.http.request",
                payload: #"{"path":"/api/health","method":"GET"}"#,
                senderID: sender
            )
            XCTAssertEqual(reply.error?.code, "unauthorized_sender", "sender: \(sender)")
        }
        let requestCount = await recorder.count()
        XCTAssertEqual(requestCount, 0)
    }

    func testRejectsUnknownMessageAndForbiddenTransportSelectorFields() async {
        let handler = makeHandler()

        let unknown = await handler.handle(type: "broker.unknown", payload: "{}", senderID: allowedSender)
        XCTAssertEqual(unknown.error?.code, "unsupported_message")
        for selector in ["service", "socket", "socketPath", "host", "port"] {
            let payload = #"{"path":"/api/health","method":"GET","PLACEHOLDER":"value"}"#
                .replacingOccurrences(of: "PLACEHOLDER", with: selector)
            let reply = await handler.handle(
                type: "broker.http.request", payload: payload, senderID: allowedSender)
            XCTAssertEqual(reply.error?.code, "invalid_payload", "selector: \(selector)")
        }
    }

    func testRejectsMalformedPayloadPathsMethodsBase64AndOversizedBodies() async {
        let handler = makeHandler(limits: limits(jsonRequestBytes: 96))
        let cases: [(String, String)] = [
            ("not-json", "invalid_payload"),
            (#"{"path":"https://localhost/api","method":"GET"}"#, "invalid_path"),
            (#"{"path":"//api/health","method":"GET"}"#, "invalid_path"),
            (#"{"path":"/api/../secret","method":"GET"}"#, "invalid_path"),
            (#"{"path":"/broker/version","method":"GET"}"#, "invalid_path"),
            (#"{"path":"/not-authorized","method":"GET"}"#, "invalid_path"),
            (#"{"path":"/api/health","method":"CONNECT"}"#, "unsupported_method"),
            (#"{"path":"/api/health","method":"POST","bodyBase64":"%%%"}"#, "invalid_base64"),
            (#"{"path":"/api/health","method":"POST","bodyBase64":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}"#, "request_too_large"),
        ]

        for (payload, expectedCode) in cases {
            let reply = await handler.handle(
                type: "broker.http.request", payload: payload, senderID: allowedSender)
            XCTAssertEqual(reply.error?.code, expectedCode, "payload: \(payload)")
        }
    }

    func testHTTPStatusAndHeadersRemainSuccessfulEnvelope() async throws {
        let handler = makeHandler(response: BrokerHTTPResponse(
            statusCode: 401,
            headers: ["www-authenticate": "Bearer", "content-type": "application/json"],
            body: Data(#"{"error":"expired"}"#.utf8)
        ))

        let reply = await handler.handle(
            type: "broker.http.request",
            payload: #"{"path":"/api/v1/chats","method":"GET"}"#,
            senderID: allowedSender
        )

        XCTAssertNil(reply.error)
        let result = try successResult(reply)
        XCTAssertEqual(result["status"] as? Int, 401)
        XCTAssertEqual(
            result["headers"] as? [[String]],
            [["content-type", "application/json"], ["www-authenticate", "Bearer"]]
        )
        XCTAssertEqual(
            Data(base64Encoded: try XCTUnwrap(result["bodyBase64"] as? String)),
            Data(#"{"error":"expired"}"#.utf8)
        )
    }

    func testStreamOpenPullAndCancelUseExactJSONMapping() async throws {
        let reader = HTTPChunkReader([Data("one".utf8), Data("two".utf8), nil])
        let store = makeStore(httpReader: reader)
        let handler = makeHandler(channelStore: store)

        let opened = await handler.handle(
            type: "broker.stream.open",
            payload: #"{"path":"/api/proactive-greeting","method":"POST"}"#,
            senderID: allowedSender
        )
        let openResult = try successResult(opened)
        let channelID = try XCTUnwrap(openResult["channelId"] as? String)
        XCTAssertEqual(openResult["status"] as? Int, 200)
        XCTAssertEqual(openResult["headers"] as? [[String]], [["content-type", "text/event-stream"]])

        let first = await pull(type: "broker.stream.pull", channelID: channelID, handler: handler)
        let second = await pull(type: "broker.stream.pull", channelID: channelID, handler: handler)
        let end = await pull(type: "broker.stream.pull", channelID: channelID, handler: handler)
        XCTAssertEqual(try firstEvent(first)["type"] as? String, "data")
        XCTAssertEqual(try firstEvent(first)["sequence"] as? Int, 0)
        XCTAssertEqual(try firstEvent(first)["data"] as? String, "b25l")
        XCTAssertEqual(try firstEvent(second)["sequence"] as? Int, 1)
        XCTAssertEqual(try firstEvent(second)["data"] as? String, "dHdv")
        XCTAssertEqual(try firstEvent(end)["type"] as? String, "end")

        let cancelled = await handler.handle(
            type: "broker.stream.cancel",
            payload: #"{"channelId":"\#(channelID)"}"#,
            senderID: allowedSender
        )
        XCTAssertNil(cancelled.error)
        XCTAssertEqual(try successResult(cancelled)["cancelled"] as? Bool, true)
    }

    func testWebSocketOpenSendPullAndCloseUseExactJSONMapping() async throws {
        let socket = FakeProtocolWebSocket(events: [
            .frame(BrokerWebSocketFrame(kind: .text, data: Data(#"{"type":"event"}"#.utf8))),
            .frame(BrokerWebSocketFrame(kind: .binary, data: Data([1, 2, 3]))),
            .close(code: 1000, reason: "done"),
        ])
        let store = makeStore(webSocket: socket)
        let handler = makeHandler(channelStore: store)

        let opened = await handler.handle(
            type: "broker.ws.open",
            payload: #"{"path":"/ws/phi-agent/execute","headers":{"Authorization":"Bearer token"}}"#,
            senderID: allowedSender
        )
        let channelID = try XCTUnwrap(try successResult(opened)["channelId"] as? String)
        let sent = await handler.handle(
            type: "broker.ws.send",
            payload: #"{"channelId":"\#(channelID)","kind":"binary","data":"BAU="}"#,
            senderID: allowedSender
        )
        XCTAssertEqual(try successResult(sent)["sent"] as? Bool, true)
        let sentFrames = await socket.sentFrames()
        XCTAssertEqual(sentFrames, [
            BrokerWebSocketFrame(kind: .binary, data: Data([4, 5])),
        ])

        let text = await pull(type: "broker.ws.pull", channelID: channelID, handler: handler)
        let binary = await pull(type: "broker.ws.pull", channelID: channelID, handler: handler)
        let close = await pull(type: "broker.ws.pull", channelID: channelID, handler: handler)
        XCTAssertEqual(try firstEvent(text)["type"] as? String, "text")
        XCTAssertEqual(try firstEvent(text)["sequence"] as? Int, 0)
        XCTAssertEqual(try firstEvent(binary)["type"] as? String, "binary")
        XCTAssertEqual(try firstEvent(binary)["sequence"] as? Int, 1)
        XCTAssertEqual(try firstEvent(close)["type"] as? String, "close")
        XCTAssertEqual(try firstEvent(close)["code"] as? Int, 1000)
        XCTAssertEqual(try firstEvent(close)["reason"] as? String, "done")

        let closed = await handler.handle(
            type: "broker.ws.close",
            payload: #"{"channelId":"\#(channelID)","code":1000,"reason":"done"}"#,
            senderID: allowedSender
        )
        XCTAssertEqual(try successResult(closed)["closed"] as? Bool, true)
    }

    func testUnknownAndCrossOwnerChannelsHaveStableErrors() async throws {
        let reader = HTTPChunkReader([nil])
        let store = makeStore(httpReader: reader)
        let handler = makeHandler(channelStore: store)

        let unknown = await pull(type: "broker.stream.pull", channelID: "missing", handler: handler)
        XCTAssertEqual(unknown.error?.code, "channel_not_found")

        let opened = try await store.openHTTPStream(
            owner: BrokerSenderContext(extensionID: allowedSender, profileID: "other-profile", accountID: nil),
            request: BrokerHTTPRequest(service: .phiAgent, path: "/api/stream")
        )
        let crossOwner = await pull(type: "broker.stream.pull", channelID: opened.channelID, handler: handler)
        XCTAssertEqual(crossOwner.error?.code, "owner_mismatch")
    }

    func testPendingPullAndTerminalEventsExposeEveryStableChannelErrorCode() async throws {
        let signal = AsyncTestSignal()
        let blockedReader = HTTPChunkReader([])
        let store = makeStore(httpReader: blockedReader, pendingPull: signal)
        let handler = makeHandler(channelStore: store)
        let opened = await handler.handle(
            type: "broker.stream.open",
            payload: #"{"path":"/api/stream","method":"GET"}"#,
            senderID: allowedSender
        )
        let channelID = try XCTUnwrap(try successResult(opened)["channelId"] as? String)
        let pending = Task { await self.pull(type: "broker.stream.pull", channelID: channelID, handler: handler) }
        await signal.wait()
        let duplicate = await pull(type: "broker.stream.pull", channelID: channelID, handler: handler)
        XCTAssertEqual(duplicate.error?.code, "pull_already_pending")
        await store.close(
            owner: BrokerSenderContext(extensionID: allowedSender, profileID: nil, accountID: nil),
            channelID: channelID,
            code: nil,
            reason: nil
        )
        _ = await pending.value

        let flowStore = makeStore(httpReader: HTTPChunkReader([Data(repeating: 0, count: 1_025)]))
        let flowHandler = makeHandler(channelStore: flowStore)
        let flowOpened = await flowHandler.handle(
            type: "broker.stream.open",
            payload: #"{"path":"/api/stream","method":"GET"}"#,
            senderID: allowedSender
        )
        let flowChannelID = try XCTUnwrap(try successResult(flowOpened)["channelId"] as? String)
        let flow = await pull(type: "broker.stream.pull", channelID: flowChannelID, handler: flowHandler)
        XCTAssertEqual(try firstEvent(flow)["code"] as? String, "flow_control_timeout")

        let upstreamStore = makeStore(httpReader: HTTPChunkReader([], failure: TestUpstreamError()))
        let upstreamHandler = makeHandler(channelStore: upstreamStore)
        let upstreamOpened = await upstreamHandler.handle(
            type: "broker.stream.open",
            payload: #"{"path":"/api/stream","method":"GET"}"#,
            senderID: allowedSender
        )
        let upstreamChannelID = try XCTUnwrap(try successResult(upstreamOpened)["channelId"] as? String)
        let upstream = await pull(
            type: "broker.stream.pull", channelID: upstreamChannelID, handler: upstreamHandler)
        XCTAssertEqual(try firstEvent(upstream)["code"] as? String, "upstream_error")

        let protocolSocket = FakeProtocolWebSocket(events: [
            .failure(code: .protocolError, message: "failure"),
        ])
        let protocolStore = makeStore(webSocket: protocolSocket)
        let protocolHandler = makeHandler(channelStore: protocolStore)
        let protocolOpened = await protocolHandler.handle(
            type: "broker.ws.open",
            payload: #"{"path":"/ws/phi-agent/execute"}"#,
            senderID: allowedSender
        )
        let protocolChannelID = try XCTUnwrap(try successResult(protocolOpened)["channelId"] as? String)
        let protocolFailure = await pull(
            type: "broker.ws.pull", channelID: protocolChannelID, handler: protocolHandler)
        XCTAssertEqual(try firstEvent(protocolFailure)["code"] as? String, "protocol_error")
    }

    func testTransportFailuresHaveStableEnvelopeErrors() async {
        let cases: [(Error, String)] = [
            (ServiceBrokerHTTPError.responseTooLarge, "response_too_large"),
            (ServiceBrokerHTTPError.invalidResponse, "protocol_error"),
            (ServiceBrokerHTTPError.connectionClosed, "upstream_error"),
        ]
        for (error, code) in cases {
            let handler = makeHandler(error: error)
            let reply = await handler.handle(
                type: "broker.http.request",
                payload: #"{"path":"/api/health","method":"GET"}"#,
                senderID: allowedSender
            )
            XCTAssertEqual(reply.error?.code, code)
        }
    }

    private func makeHandler(
        limits: ServiceBrokerLimits? = nil,
        response: BrokerHTTPResponse = BrokerHTTPResponse(
            statusCode: 401, headers: ["content-type": "application/json"], body: Data("{}".utf8)
        ),
        error: Error? = nil,
        recorder: BrokerRequestRecorder = BrokerRequestRecorder(),
        channelStore: ServiceBrokerChannelStore? = nil
    ) -> ServiceBrokerExtensionProtocol {
        let resolvedLimits = limits ?? self.limits()
        let resolvedStore = channelStore ?? makeStore(httpReader: HTTPChunkReader([nil]))
        return ServiceBrokerExtensionProtocol(
            limits: resolvedLimits,
            channelStore: resolvedStore,
            requestExecutor: { request in
                await recorder.record(request)
                if let error { throw error }
                return response
            }
        )
    }

    private func makeStore(
        httpReader: HTTPChunkReader? = nil,
        webSocket: FakeProtocolWebSocket? = nil,
        pendingPull: AsyncTestSignal? = nil
    ) -> ServiceBrokerChannelStore {
        ServiceBrokerChannelStore(
            configuration: ServiceBrokerChannelConfiguration(
                bridgeChunkBytes: 64,
                webSocketMessageBytes: 1_024,
                unacknowledgedWindowBytes: 1_024,
                pullTimeout: .seconds(1),
                idleTimeout: .seconds(10)
            ),
            httpStreamOpener: { _ in
                let reader = try XCTUnwrap(httpReader)
                return BrokerHTTPStreamSource(
                    response: BrokerHTTPResponseHead(
                        statusCode: 200,
                        headers: ["content-type": "text/event-stream"]
                    ),
                    read: { maxBytes in try await reader.read(maxBytes: maxBytes) },
                    cancel: { Task { await reader.cancel() } }
                )
            },
            webSocketOpener: { _, _ in
                try XCTUnwrap(webSocket).source
            },
            pendingPullObserver: { _ in
                guard let pendingPull else { return }
                Task { await pendingPull.signal() }
            }
        )
    }

    private func limits(jsonRequestBytes: Int = 1_024) -> ServiceBrokerLimits {
        ServiceBrokerLimits(
            bridgeChunkBytes: 512,
            jsonRequestBytes: jsonRequestBytes,
            nonStreamingResponseBytes: 1_024,
            webSocketMessageBytes: 1_024,
            unacknowledgedWindowBytes: 1_024,
            stagedFileBytes: 1_024,
            stagedAccountBytes: 1_024
        )
    }

    private func pull(
        type: String,
        channelID: String,
        handler: ServiceBrokerExtensionProtocol
    ) async -> ServiceBrokerExtensionReply {
        await handler.handle(
            type: type,
            payload: #"{"channelId":"\#(channelID)"}"#,
            senderID: allowedSender
        )
    }

    private func successResult(
        _ reply: ServiceBrokerExtensionReply,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        XCTAssertNil(reply.error, file: file, line: line)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(reply.json.utf8)) as? [String: Any],
            file: file,
            line: line
        )
        XCTAssertEqual(root["ok"] as? Bool, true, file: file, line: line)
        return try XCTUnwrap(root["result"] as? [String: Any], file: file, line: line)
    }

    private func firstEvent(
        _ reply: ServiceBrokerExtensionReply,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let result = try successResult(reply, file: file, line: line)
        let events = try XCTUnwrap(result["events"] as? [[String: Any]], file: file, line: line)
        return try XCTUnwrap(events.first, file: file, line: line)
    }
}

private actor BrokerRequestRecorder {
    private var requests = [BrokerHTTPRequest]()

    func record(_ request: BrokerHTTPRequest) {
        requests.append(request)
    }

    func lastRequest() -> BrokerHTTPRequest? {
        requests.last
    }

    func count() -> Int {
        requests.count
    }
}

private actor HTTPChunkReader {
    private var chunks: [Data?]
    private var failure: (any Error)?
    private var waiters = [CheckedContinuation<Data?, Never>]()

    init(_ chunks: [Data?], failure: (any Error)? = nil) {
        self.chunks = chunks
        self.failure = failure
    }

    func read(maxBytes: Int) async throws -> Data? {
        if !chunks.isEmpty {
            return chunks.removeFirst()
        }
        if let failure {
            self.failure = nil
            throw failure
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func cancel() {
        for waiter in waiters { waiter.resume(returning: nil) }
        waiters.removeAll()
    }
}

private actor FakeProtocolWebSocket {
    private var events: [BrokerWebSocketEvent]
    private var sent = [BrokerWebSocketFrame]()
    private var waiters = [CheckedContinuation<BrokerWebSocketEvent, Never>]()

    init(events: [BrokerWebSocketEvent]) {
        self.events = events
    }

    nonisolated var source: BrokerWebSocketSource {
        BrokerWebSocketSource(
            send: { frame in await self.record(frame) },
            receive: { await self.next() },
            close: { code, reason in await self.finish(code: code, reason: reason) }
        )
    }

    func sentFrames() -> [BrokerWebSocketFrame] {
        sent
    }

    private func record(_ frame: BrokerWebSocketFrame) {
        sent.append(frame)
    }

    private func next() async -> BrokerWebSocketEvent {
        if !events.isEmpty {
            return events.removeFirst()
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func finish(code: UInt16?, reason: String?) {
        for waiter in waiters { waiter.resume(returning: .close(code: code, reason: reason)) }
        waiters.removeAll()
    }
}

private actor AsyncTestSignal {
    private var signalled = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func signal() {
        signalled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private struct TestUpstreamError: Error {}
