import Darwin
import XCTest
@testable import Phi

final class ServiceBrokerClientTests: XCTestCase {
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

    func testRequestRoutesPhiAgentPathOverUnixSocket() async throws {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}")
        let client = ServiceBrokerClient(socketPath: server.socketPath)

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
        XCTAssertEqual(response.headers["content-type"], "application/json")
        XCTAssertEqual(response.body, Data(#"{"ok":true}"#.utf8))
    }

    func testRequestParsesChunkedBody() async throws {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
        let client = ServiceBrokerClient(socketPath: server.socketPath)

        let response = try await client.request(BrokerHTTPRequest(service: .phiAgent, path: "/stream"))

        XCTAssertEqual(response.body, Data("hello world".utf8))
    }

    func testRequestParsesEOFDelimitedBody() async throws {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nconnection closed body")
        let client = ServiceBrokerClient(socketPath: server.socketPath)

        let response = try await client.request(BrokerHTTPRequest(service: .phiAgent, path: "/logs"))

        XCTAssertEqual(response.body, Data("connection closed body".utf8))
    }
}

private final class UnixHTTPTestServer: @unchecked Sendable {
    let socketPath: String

    private let listener: Int32
    private let response: Data
    private let lock = NSLock()
    private var capturedRequest = Data()

    init(response: String) {
        socketPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("phi-service-broker-\(UUID().uuidString).sock")
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
