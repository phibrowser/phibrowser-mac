import Darwin
import XCTest
@testable import Phi

extension ServiceBrokerPeerAuthenticator {
    static let allowingTests = ServiceBrokerPeerAuthenticator { _ in }
}

final class ServiceBrokerClientTests: XCTestCase {
    private func makeClient(
        socketPath: String,
        nonStreamingResponseBytes: Int = 16 * 1024 * 1024
    ) -> ServiceBrokerClient {
        ServiceBrokerClient(
            socketPath: socketPath,
            nonStreamingResponseBytes: nonStreamingResponseBytes,
            peerAuthenticator: .allowingTests
        )
    }

    func testVersionNegotiationAcceptsCurrentMajorOnly() {
        XCTAssertEqual(
            ServiceBrokerNegotiation.evaluate(protocolVersion: 1),
            .broker
        )
        XCTAssertEqual(
            ServiceBrokerNegotiation.evaluate(protocolVersion: 2),
            .protocolUnsupported
        )
    }

    func testFallbackIsRestrictedToApprovedCompatibilityReasons() {
        XCTAssertTrue(ServiceBrokerFallbackReason.brokerUnavailable.allowsLoopback)
        XCTAssertTrue(ServiceBrokerFallbackReason.protocolUnsupported.allowsLoopback)
        XCTAssertTrue(ServiceBrokerFallbackReason.signedCompatibilityConfig.allowsLoopback)
        XCTAssertFalse(ServiceBrokerFallbackReason.authorizationDenied.allowsLoopback)
        XCTAssertFalse(ServiceBrokerFallbackReason.invalidRequest.allowsLoopback)
        XCTAssertFalse(ServiceBrokerFallbackReason.sizeLimitExceeded.allowsLoopback)
    }

    func testRejectsUnauthenticatedBrokerPeerBeforeSendingCredentials() async {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        let client = ServiceBrokerClient(
            socketPath: server.socketPath,
            peerAuthenticator: ServiceBrokerPeerAuthenticator { _ in
                throw ServiceBrokerHTTPError.peerAuthentication
            }
        )

        await assertBrokerHTTPError(.peerAuthentication) {
            _ = try await client.request(BrokerHTTPRequest(
                service: .phiAgent,
                path: "/api/private",
                headers: ["Authorization": "Bearer must-not-leak"]
            ))
        }
        XCTAssertNil(server.requestMethod)
    }

    func testConfiguresNoSigPipeBeforePeerAuthenticationAndHTTPWrite() async throws {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        let client = ServiceBrokerClient(
            socketPath: server.socketPath,
            peerAuthenticator: ServiceBrokerPeerAuthenticator { descriptor in
                var enabled: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    &enabled,
                    &length
                ) == 0, enabled == 1 else {
                    throw ServiceBrokerHTTPError.peerAuthentication
                }
            }
        )

        let response = try await client.request(BrokerHTTPRequest(
            service: .phiAgent,
            path: "/api/health"
        ))

        XCTAssertEqual(response.statusCode, 200)
    }

    func testTimesOutWhenHTTPPeerStallsBeforeResponseHeaders() async {
        let server = UnixHTTPStallServer()
        let client = ServiceBrokerClient(
            socketPath: server.socketPath,
            peerAuthenticator: .allowingTests,
            ioTimeoutMilliseconds: 50
        )

        await assertBrokerHTTPError(.timedOut) {
            _ = try await client.request(BrokerHTTPRequest(
                service: .phiAgent,
                path: "/api/stall"
            ))
        }
    }

    func testTaskCancellationClosesStalledHTTPConnection() async throws {
        let server = UnixHTTPStallServer()
        let client = ServiceBrokerClient(
            socketPath: server.socketPath,
            peerAuthenticator: .allowingTests,
            ioTimeoutMilliseconds: 5_000
        )
        let request = Task {
            try await client.request(BrokerHTTPRequest(
                service: .phiAgent,
                path: "/api/stall"
            ))
        }
        try await Task.sleep(for: .milliseconds(25))

        request.cancel()

        do {
            _ = try await request.value
            XCTFail("Expected cancellation to close the stalled connection.")
        } catch let error as ServiceBrokerHTTPError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Expected cancelled, got \(error).")
        }
    }

    func testRequestRoutesPhiAgentPathOverUnixSocket() async throws {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}")
        let client = makeClient(socketPath: server.socketPath)

        let response = try await client.request(BrokerHTTPRequest(
            service: .phiAgent,
            path: "/api/v1/chats?limit=20",
            method: "POST",
            headers: ["Authorization": "Bearer token"],
            body: Data("request".utf8)
        ))

        XCTAssertEqual(server.requestMethod, "POST")
        XCTAssertEqual(server.requestTarget, "/phi-agent/api/v1/chats?limit=20")
        XCTAssertEqual(server.requestHeaders["authorization"], "Bearer token")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers, [
            BrokerHTTPHeader(name: "content-type", value: "application/json"),
            BrokerHTTPHeader(name: "content-length", value: "11"),
        ])
        XCTAssertEqual(response.body, Data(#"{"ok":true}"#.utf8))
    }

    func testResponsePreservesRepeatedHeadersInWireOrder() async throws {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 401 Unauthorized\r\n" +
                "Set-Cookie: first=1\r\n" +
                "WWW-Authenticate: Bearer realm=one\r\n" +
                "Set-Cookie: second=2\r\n" +
                "WWW-Authenticate: Basic realm=two\r\n" +
                "Content-Length: 0\r\n\r\n")
        let client = makeClient(socketPath: server.socketPath)

        let response = try await client.request(BrokerHTTPRequest(service: .phiAgent, path: "/auth"))

        XCTAssertEqual(response.headers, [
            BrokerHTTPHeader(name: "set-cookie", value: "first=1"),
            BrokerHTTPHeader(name: "www-authenticate", value: "Bearer realm=one"),
            BrokerHTTPHeader(name: "set-cookie", value: "second=2"),
            BrokerHTTPHeader(name: "www-authenticate", value: "Basic realm=two"),
            BrokerHTTPHeader(name: "content-length", value: "0"),
        ])
    }

    func testRequestParsesChunkedBody() async throws {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
        let client = makeClient(socketPath: server.socketPath)

        let response = try await client.request(BrokerHTTPRequest(service: .phiAgent, path: "/stream"))

        XCTAssertEqual(response.body, Data("hello world".utf8))
    }

    func testRequestParsesEOFDelimitedBody() async throws {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nconnection closed body")
        let client = makeClient(socketPath: server.socketPath)

        let response = try await client.request(BrokerHTTPRequest(service: .phiAgent, path: "/logs"))

        XCTAssertEqual(response.body, Data("connection closed body".utf8))
    }

    func testRequestRejectsInvalidContentLengthForNoBodyStatus() async {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 204 No Content\r\nContent-Length: invalid\r\n\r\n")
        let client = makeClient(socketPath: server.socketPath)

        await assertBrokerHTTPError(.invalidResponse) {
            _ = try await client.request(BrokerHTTPRequest(service: .phiAgent, path: "/empty"))
        }
    }

    func testRequestRejectsConflictingFramingForNoBodyStatus() async {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n")
        let client = makeClient(socketPath: server.socketPath)

        await assertBrokerHTTPError(.invalidResponse) {
            _ = try await client.request(BrokerHTTPRequest(service: .phiAgent, path: "/empty"))
        }
    }

    func testRequestRejectsControlCharacterInStatusLine() async {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 200 O\u{000B}K\r\nContent-Length: 0\r\n\r\n")
        let client = makeClient(socketPath: server.socketPath)

        await assertBrokerHTTPError(.invalidResponse) {
            _ = try await client.request(BrokerHTTPRequest(service: .phiAgent, path: "/status"))
        }
    }

    func testRequestRejectsPercentEncodedDotSegment() async {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        let client = makeClient(socketPath: server.socketPath)

        await assertBrokerHTTPError(.invalidRequest) {
            _ = try await client.request(BrokerHTTPRequest(
                service: .phiAgent,
                path: "/%2e%2e/broker"
            ))
        }
    }

    func testServiceSubpathNamedBrokerIsForwardedToTheSelectedService() async throws {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        let client = makeClient(socketPath: server.socketPath)

        _ = try await client.request(BrokerHTTPRequest(
            service: .phiAgent,
            path: "/broker/status"
        ))

        XCTAssertEqual(server.requestTarget, "/phi-agent/broker/status")
    }

    func testOpenStreamReadsFixedLengthResponseInChunks() async throws {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")
        let client = makeClient(socketPath: server.socketPath)

        let stream = try await client.openStream(BrokerHTTPRequest(service: .phiAgent, path: "/stream"))
        defer { stream.cancel() }

        XCTAssertEqual(stream.response.statusCode, 200)
        let firstChunk = try await stream.read(maxBytes: 3)
        let secondChunk = try await stream.read(maxBytes: 3)
        let end = try await stream.read(maxBytes: 3)
        XCTAssertEqual(firstChunk, Data("hel".utf8))
        XCTAssertEqual(secondChunk, Data("lo".utf8))
        XCTAssertNil(end)
    }

    func testOpenStreamMayConsumeBeyondNonStreamingResponseLimit() async throws {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\n12345678")
        let client = makeClient(socketPath: server.socketPath, nonStreamingResponseBytes: 4)
        let stream = try await client.openStream(BrokerHTTPRequest(service: .phiAgent, path: "/stream"))
        defer { stream.cancel() }

        let first = try await stream.read(maxBytes: 4)
        let second = try await stream.read(maxBytes: 4)
        let end = try await stream.read(maxBytes: 4)
        XCTAssertEqual(first, Data("1234".utf8))
        XCTAssertEqual(second, Data("5678".utf8))
        XCTAssertNil(end)
    }

    func testStreamingBodyReadSurvivesUpstreamGapLongerThanIOTimeout() async throws {
        let server = UnixHTTPStreamingTestServer(
            head: "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nfirst\r\n",
            chunks: [(delayMilliseconds: 300, body: "6\r\nsecond\r\n")]
        )
        let client = ServiceBrokerClient(
            socketPath: server.socketPath,
            peerAuthenticator: .allowingTests,
            ioTimeoutMilliseconds: 50
        )
        let stream = try await client.openStream(BrokerHTTPRequest(service: .phiAgent, path: "/stream"))
        defer { stream.cancel() }

        let first = try await stream.read(maxBytes: 1_024)
        let second = try await stream.read(maxBytes: 1_024)

        XCTAssertEqual(first, Data("first".utf8))
        XCTAssertEqual(second, Data("second".utf8))
    }

    func testCancelUnblocksStalledStreamingBodyRead() async throws {
        let server = UnixHTTPStreamingTestServer(
            head: "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        )
        let client = ServiceBrokerClient(
            socketPath: server.socketPath,
            peerAuthenticator: .allowingTests,
            ioTimeoutMilliseconds: 5_000
        )
        let stream = try await client.openStream(BrokerHTTPRequest(service: .phiAgent, path: "/stream"))
        defer { stream.cancel() }

        let reader = Task { try await stream.read(maxBytes: 1_024) }
        try await Task.sleep(for: .milliseconds(50))
        let cancelledAt = DispatchTime.now()
        reader.cancel()

        do {
            _ = try await reader.value
            XCTFail("Expected the stalled streaming body read to be cancelled.")
        } catch let error as ServiceBrokerHTTPError {
            XCTAssertEqual(error, .cancelled)
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - cancelledAt.uptimeNanoseconds)
            / 1_000_000_000
        XCTAssertLessThan(seconds, 1, "Cancellation must unblock a stalled body read promptly.")
    }

    func testNonStreamingRequestStillEnforcesAggregateResponseLimit() async {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\n12345678")
        let client = makeClient(socketPath: server.socketPath, nonStreamingResponseBytes: 4)

        await assertBrokerHTTPError(.responseTooLarge) {
            _ = try await client.request(BrokerHTTPRequest(service: .phiAgent, path: "/request"))
        }
    }
}

private func assertBrokerHTTPError(
    _ expected: ServiceBrokerHTTPError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: @escaping () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected ServiceBrokerHTTPError.\(expected)", file: file, line: line)
    } catch let error as ServiceBrokerHTTPError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected ServiceBrokerHTTPError.\(expected), got \(error)", file: file, line: line)
    }
}

private final class UnixHTTPTestServer: @unchecked Sendable {
    let socketPath: String

    private let listener: Int32
    private let response: Data
    private let lock = NSLock()
    private var capturedRequest = Data()

    init(response: String) {
        socketPath = "/tmp/phi-broker-\(UUID().uuidString).sock"
        self.response = Data(response.utf8)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(listener >= 0)

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            socketPath.withCString { source in
                strncpy(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), source, buffer.count - 1)
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(result == 0)
        precondition(listen(listener, 1) == 0)

        DispatchQueue.global().async { [self] in
            serveOneRequest()
        }
    }

    deinit {
        close(listener)
        unlink(socketPath)
    }

    var requestMethod: String? { requestLine?.split(separator: " ").first.map(String.init) }

    var requestTarget: String? {
        let parts = requestLine?.split(separator: " ")
        return parts?.dropFirst().first.map(String.init)
    }

    var requestHeaders: [String: String] {
        guard let request = String(data: requestData, encoding: .utf8),
              let separator = request.range(of: "\r\n\r\n") else {
            return [:]
        }
        return request[..<separator.lowerBound]
            .split(separator: "\r\n")
            .dropFirst()
            .reduce(into: [:]) { headers, line in
                guard let colon = line.firstIndex(of: ":") else { return }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
    }

    private var requestData: Data {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequest
    }

    private var requestLine: String? {
        guard let request = String(data: requestData, encoding: .utf8) else { return nil }
        return request.components(separatedBy: "\r\n").first
    }

    private func serveOneRequest() {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }
        defer { close(connection) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            connection,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { return }
            request.append(buffer, count: count)
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                lock.lock()
                capturedRequest = request
                lock.unlock()
                break
            }
        }

        response.withUnsafeBytes { bytes in
            guard let pointer = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = write(connection, pointer.advanced(by: written), bytes.count - written)
                guard count > 0 else { return }
                written += count
            }
        }
    }
}

/// Serves one response head immediately and then drip-feeds body chunks with
/// deliberate gaps, so a streaming read can be exercised across upstream silence.
private final class UnixHTTPStreamingTestServer: @unchecked Sendable {
    let socketPath: String

    private let listener: Int32
    private let head: Data
    private let chunks: [(delayMilliseconds: Int, body: Data)]

    init(head: String, chunks: [(delayMilliseconds: Int, body: String)] = []) {
        socketPath = "/tmp/phi-broker-stream-\(UUID().uuidString).sock"
        self.head = Data(head.utf8)
        self.chunks = chunks.map { ($0.delayMilliseconds, Data($0.body.utf8)) }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(listener >= 0)

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            socketPath.withCString { source in
                strncpy(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), source, buffer.count - 1)
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(result == 0)
        precondition(listen(listener, 1) == 0)

        DispatchQueue.global().async { [self] in serve() }
    }

    deinit {
        Darwin.close(listener)
        unlink(socketPath)
    }

    private func serve() {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }
        defer { Darwin.close(connection) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            connection,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { return }
            request.append(buffer, count: count)
        }

        writeAll(head, to: connection)
        for chunk in chunks {
            Thread.sleep(forTimeInterval: Double(chunk.delayMilliseconds) / 1_000)
            writeAll(chunk.body, to: connection)
        }

        // Hold the connection open so the client observes silence rather than EOF.
        var byte: UInt8 = 0
        while Darwin.read(connection, &byte, 1) > 0 {}
    }

    private func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { return }
                offset += count
            }
        }
    }
}

private final class UnixHTTPStallServer: @unchecked Sendable {
    let socketPath: String

    private let listener: Int32

    init() {
        socketPath = "/tmp/phi-broker-stall-\(UUID().uuidString).sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(listener >= 0)

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            socketPath.withCString { source in
                strncpy(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), source, buffer.count - 1)
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(result == 0)
        precondition(listen(listener, 1) == 0)

        DispatchQueue.global().async { [self] in
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            defer { Darwin.close(connection) }
            var byte: UInt8 = 0
            while Darwin.read(connection, &byte, 1) > 0 {}
        }
    }

    deinit {
        Darwin.close(listener)
        unlink(socketPath)
    }
}
