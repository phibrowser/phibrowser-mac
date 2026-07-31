import Darwin
import CryptoKit
import Foundation
import XCTest
@testable import Phi

final class ServiceBrokerWebSocketTests: XCTestCase {
    func testWebSocketTextBinaryAndCloseFramesRoundTrip() async throws {
        let server = UnixWebSocketTestServer()
        let socket = ServiceBrokerWebSocket(socketPath: server.socketPath, maximumMessageBytes: 1_024)

        try await socket.connect(
            path: "/ws/phi-agent/execute",
            headers: ["Authorization": "Bearer token"]
        )
        try await socket.send(BrokerWebSocketFrame(kind: .text, data: Data("hello".utf8)))
        try await socket.send(BrokerWebSocketFrame(kind: .binary, data: Data([0, 1, 2])))

        let text = try await socket.receive()
        let binary = try await socket.receive()
        let close = try await socket.receive()
        XCTAssertEqual(text, .frame(
            sequence: 0, BrokerWebSocketFrame(kind: .text, data: Data("reply".utf8))))
        XCTAssertEqual(binary, .frame(
            sequence: 1, BrokerWebSocketFrame(kind: .binary, data: Data([3, 4, 5]))))
        XCTAssertEqual(close, .close(code: 1000, reason: "done"))
        XCTAssertEqual(server.requestTarget, "/phi-agent/ws/phi-agent/execute")
        XCTAssertEqual(server.requestHeaders["authorization"], "Bearer token")
        XCTAssertEqual(server.receivedFrames, [
            BrokerWebSocketFrame(kind: .text, data: Data("hello".utf8)),
            BrokerWebSocketFrame(kind: .binary, data: Data([0, 1, 2]))
        ])
        let echoedClose = await server.waitForCloseEcho()
        XCTAssertEqual(echoedClose.opcode, 0x8)
        XCTAssertTrue(echoedClose.masked)
        XCTAssertEqual(echoedClose.payload, Data([0x03, 0xE8]) + Data("done".utf8))
    }

    func testWebSocketReassemblesContinuationAndAnswersPing() async throws {
        let server = UnixWebSocketTestServer(script: .continuationAndPing)
        let socket = ServiceBrokerWebSocket(socketPath: server.socketPath, maximumMessageBytes: 1_024)
        try await socket.connect(path: "/ws/phi-agent/execute", headers: [:])

        let event = try await socket.receive()

        XCTAssertEqual(event, .frame(
            sequence: 0, BrokerWebSocketFrame(kind: .text, data: Data("hello".utf8))))
        for _ in 0..<20 where server.receivedPong != Data("ping".utf8) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(server.receivedPong, Data("ping".utf8))
        await socket.close(code: 1000, reason: nil)
    }

    func testWebSocketRejectsMaskedServerFrameAsProtocolError() async throws {
        let server = UnixWebSocketTestServer(script: .maskedServerFrame)
        let socket = ServiceBrokerWebSocket(socketPath: server.socketPath, maximumMessageBytes: 1_024)
        try await socket.connect(path: "/ws/phi-agent/execute", headers: [:])

        do {
            _ = try await socket.receive()
            XCTFail("Expected a protocol error.")
        } catch let error as ServiceBrokerWebSocketError {
            XCTAssertEqual(error, .protocolError)
        }
    }

    func testWebSocketRejectsOversizedServerFrameAsProtocolError() async throws {
        let server = UnixWebSocketTestServer(script: .oversizedServerFrame)
        let socket = ServiceBrokerWebSocket(socketPath: server.socketPath, maximumMessageBytes: 4)
        try await socket.connect(path: "/ws/phi-agent/execute", headers: [:])

        do {
            _ = try await socket.receive()
            XCTFail("Expected a protocol error.")
        } catch let error as ServiceBrokerWebSocketError {
            XCTAssertEqual(error, .protocolError)
        }
    }

    func testWebSocketRejectsHandshakeWithBadStatus() async {
        await assertInvalidHandshake(.badStatus)
    }

    func testWebSocketRejectsHandshakeWithBadUpgrade() async {
        await assertInvalidHandshake(.badUpgrade)
    }

    func testWebSocketRejectsHandshakeWithBadConnection() async {
        await assertInvalidHandshake(.badConnection)
    }

    func testWebSocketRejectsHandshakeWithBadAccept() async {
        await assertInvalidHandshake(.badAccept)
    }

    func testWebSocketRejectsUnexpectedContinuation() async throws {
        try await assertProtocolError(.unexpectedContinuation)
    }

    func testWebSocketRejectsDataFrameDuringFragmentation() async throws {
        try await assertProtocolError(.dataDuringFragmentation)
    }

    func testWebSocketRejectsFragmentedControlFrame() async throws {
        try await assertProtocolError(.fragmentedControl)
    }

    func testWebSocketRejectsOversizedControlFrame() async throws {
        try await assertProtocolError(.oversizedControl)
    }

    func testWebSocketRejectsInvalidTextUTF8() async throws {
        try await assertProtocolError(.invalidTextUTF8)
    }

    func testWebSocketRejectsInvalidCloseReasonUTF8() async throws {
        try await assertProtocolError(.invalidCloseUTF8)
    }

    func testWebSocketRejectsInvalidCloseCode() async throws {
        try await assertProtocolError(.invalidCloseCode)
    }

    func testWebSocketRejectsFragmentedAggregateOverflow() async throws {
        try await assertProtocolError(.fragmentedAggregateOverflow, maximumMessageBytes: 4)
    }

    func testInvalidLocalCloseStillClosesDescriptor() async throws {
        let eof = expectation(description: "server observes client descriptor close")
        let server = UnixWebSocketTestServer(script: .waitForClientEOF, onClientEOF: { eof.fulfill() })
        let socket = ServiceBrokerWebSocket(socketPath: server.socketPath, maximumMessageBytes: 1_024)
        try await socket.connect(path: "/ws/phi-agent/execute", headers: [:])

        await socket.close(code: nil, reason: "reason without code")

        await fulfillment(of: [eof], timeout: 1)
    }

    private func assertInvalidHandshake(
        _ script: UnixWebSocketTestServer.Script,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let server = UnixWebSocketTestServer(script: script)
        let socket = ServiceBrokerWebSocket(socketPath: server.socketPath, maximumMessageBytes: 1_024)
        do {
            try await socket.connect(path: "/ws/phi-agent/execute", headers: [:])
            XCTFail("Expected invalid handshake.", file: file, line: line)
        } catch let error as ServiceBrokerWebSocketError {
            XCTAssertEqual(error, .invalidResponse, file: file, line: line)
        } catch {
            XCTFail("Expected invalidResponse, got \(error).", file: file, line: line)
        }
    }

    private func assertProtocolError(
        _ script: UnixWebSocketTestServer.Script,
        maximumMessageBytes: Int = 1_024,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let server = UnixWebSocketTestServer(script: script)
        let socket = ServiceBrokerWebSocket(
            socketPath: server.socketPath,
            maximumMessageBytes: maximumMessageBytes
        )
        try await socket.connect(path: "/ws/phi-agent/execute", headers: [:])
        do {
            _ = try await socket.receive()
            XCTFail("Expected a protocol error.", file: file, line: line)
        } catch let error as ServiceBrokerWebSocketError {
            XCTAssertEqual(error, .protocolError, file: file, line: line)
        }
    }
}

private final class UnixWebSocketTestServer: @unchecked Sendable {
    enum Script: Equatable {
        case roundTrip
        case continuationAndPing
        case maskedServerFrame
        case oversizedServerFrame
        case badStatus
        case badUpgrade
        case badConnection
        case badAccept
        case unexpectedContinuation
        case dataDuringFragmentation
        case fragmentedControl
        case oversizedControl
        case invalidTextUTF8
        case invalidCloseUTF8
        case invalidCloseCode
        case fragmentedAggregateOverflow
        case waitForClientEOF
    }

    let socketPath: String

    private let listener: Int32
    private let script: Script
    private let lock = NSLock()
    private var capturedRequest = Data()
    private var frames = [BrokerWebSocketFrame]()
    private var pong: Data?
    private var closeEcho: (opcode: UInt8, masked: Bool, payload: Data)?
    private var closeEchoWaiters = [CheckedContinuation<(opcode: UInt8, masked: Bool, payload: Data), Never>]()
    private let onClientEOF: @Sendable () -> Void

    init(script: Script = .roundTrip, onClientEOF: @escaping @Sendable () -> Void = {}) {
        socketPath = "/tmp/phi-broker-ws-\(UUID().uuidString).sock"
        self.script = script
        self.onClientEOF = onClientEOF
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

    var requestTarget: String? {
        requestLine?.split(separator: " ").dropFirst().first.map(String.init)
    }

    var requestHeaders: [String: String] {
        guard let request = String(data: requestData, encoding: .utf8),
              let separator = request.range(of: "\r\n\r\n") else { return [:] }
        return request[..<separator.lowerBound]
            .split(separator: "\r\n")
            .dropFirst()
            .reduce(into: [:]) { headers, line in
                guard let colon = line.firstIndex(of: ":") else { return }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
    }

    var receivedFrames: [BrokerWebSocketFrame] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    var receivedPong: Data? {
        lock.lock()
        defer { lock.unlock() }
        return pong
    }

    func waitForCloseEcho() async -> (opcode: UInt8, masked: Bool, payload: Data) {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let closeEcho {
                lock.unlock()
                continuation.resume(returning: closeEcho)
            } else {
                closeEchoWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private var requestData: Data {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequest
    }

    private var requestLine: String? {
        String(data: requestData, encoding: .utf8)?.components(separatedBy: "\r\n").first
    }

    private func serve() {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }
        defer { Darwin.close(connection) }

        let request = readThroughHeaders(connection)
        lock.lock()
        capturedRequest = request
        lock.unlock()
        guard let key = requestHeaders["sec-websocket-key"] else { return }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(digest).base64EncodedString()
        let status = script == .badStatus ? "HTTP/1.1 200 OK" : "HTTP/1.1 101 Switching Protocols"
        let upgrade = script == .badUpgrade ? "not-websocket" : "websocket"
        let connectionHeader = script == .badConnection ? "keep-alive" : "Upgrade"
        let acceptHeader = script == .badAccept ? "wrong" : accept
        writeAll(Data((
            "\(status)\r\n" +
            "Upgrade: \(upgrade)\r\n" +
            "Connection: \(connectionHeader)\r\n" +
            "Sec-WebSocket-Accept: \(acceptHeader)\r\n\r\n"
        ).utf8), to: connection)

        switch script {
        case .roundTrip:
            guard let first = readClientFrame(connection), let second = readClientFrame(connection) else { return }
            lock.lock()
            frames = [first, second]
            lock.unlock()
            writeServerFrame(opcode: 0x1, payload: Data("reply".utf8), to: connection)
            writeServerFrame(opcode: 0x2, payload: Data([3, 4, 5]), to: connection)
            var closePayload = Data([0x03, 0xE8])
            closePayload.append(Data("done".utf8))
            writeServerFrame(opcode: 0x8, payload: closePayload, to: connection)
            if let echo = readRawFrame(connection) { recordCloseEcho(echo) }
        case .continuationAndPing:
            writeServerFrame(opcode: 0x9, payload: Data("ping".utf8), to: connection)
            writeServerFrame(final: false, opcode: 0x1, payload: Data("hel".utf8), to: connection)
            writeServerFrame(opcode: 0x0, payload: Data("lo".utf8), to: connection)
            if let frame = readRawFrame(connection), frame.opcode == 0xA {
                lock.lock()
                pong = frame.payload
                lock.unlock()
            }
            _ = readRawFrame(connection)
        case .maskedServerFrame:
            writeServerFrame(masked: true, opcode: 0x1, payload: Data("bad".utf8), to: connection)
            _ = readRawFrame(connection)
        case .oversizedServerFrame:
            writeServerFrame(opcode: 0x2, payload: Data([0, 1, 2, 3, 4]), to: connection)
            _ = readRawFrame(connection)
        case .badStatus, .badUpgrade, .badConnection, .badAccept:
            return
        case .unexpectedContinuation:
            writeServerFrame(opcode: 0x0, payload: Data("bad".utf8), to: connection)
            _ = readRawFrame(connection)
        case .dataDuringFragmentation:
            writeServerFrame(final: false, opcode: 0x1, payload: Data("a".utf8), to: connection)
            writeServerFrame(opcode: 0x2, payload: Data("b".utf8), to: connection)
            _ = readRawFrame(connection)
        case .fragmentedControl:
            writeServerFrame(final: false, opcode: 0x9, payload: Data("bad".utf8), to: connection)
            _ = readRawFrame(connection)
        case .oversizedControl:
            writeServerFrame(opcode: 0x9, payload: Data(repeating: 0, count: 126), to: connection)
            _ = readRawFrame(connection)
        case .invalidTextUTF8:
            writeServerFrame(opcode: 0x1, payload: Data([0xC3, 0x28]), to: connection)
            _ = readRawFrame(connection)
        case .invalidCloseUTF8:
            writeServerFrame(opcode: 0x8, payload: Data([0x03, 0xE8, 0xC3, 0x28]), to: connection)
            _ = readRawFrame(connection)
        case .invalidCloseCode:
            writeServerFrame(opcode: 0x8, payload: Data([0x03, 0xED]), to: connection)
            _ = readRawFrame(connection)
        case .fragmentedAggregateOverflow:
            writeServerFrame(final: false, opcode: 0x2, payload: Data([0, 1, 2]), to: connection)
            writeServerFrame(opcode: 0x0, payload: Data([3, 4]), to: connection)
            _ = readRawFrame(connection)
        case .waitForClientEOF:
            var byte: UInt8 = 0
            if Darwin.read(connection, &byte, 1) == 0 { onClientEOF() }
        }
    }

    private func recordCloseEcho(_ frame: (opcode: UInt8, masked: Bool, payload: Data)) {
        lock.lock()
        closeEcho = frame
        let waiters = closeEchoWaiters
        closeEchoWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(returning: frame) }
    }

    private func readThroughHeaders(_ descriptor: Int32) -> Data {
        var data = Data()
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard let chunk = readExact(descriptor, count: 1) else { return data }
            data.append(chunk)
        }
        return data
    }

    private func readClientFrame(_ descriptor: Int32) -> BrokerWebSocketFrame? {
        guard let raw = readRawFrame(descriptor), raw.masked else { return nil }
        switch raw.opcode {
        case 0x1: return BrokerWebSocketFrame(kind: .text, data: raw.payload)
        case 0x2: return BrokerWebSocketFrame(kind: .binary, data: raw.payload)
        default: return nil
        }
    }

    private func readRawFrame(_ descriptor: Int32) -> (opcode: UInt8, masked: Bool, payload: Data)? {
        guard let header = readExact(descriptor, count: 2) else { return nil }
        let bytes = [UInt8](header)
        let masked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7F)
        if length == 126 {
            guard let extended = readExact(descriptor, count: 2) else { return nil }
            length = Int(UInt16(extended[extended.startIndex]) << 8 | UInt16(extended[extended.index(after: extended.startIndex)]))
        }
        guard length < 127 else { return nil }
        let mask = masked ? readExact(descriptor, count: 4) : Data()
        guard !masked || mask != nil, let encoded = readExact(descriptor, count: length) else { return nil }
        var payload = [UInt8](encoded)
        if let mask {
            let maskBytes = [UInt8](mask)
            for index in payload.indices { payload[index] ^= maskBytes[index % 4] }
        }
        return (bytes[0] & 0x0F, masked, Data(payload))
    }

    private func writeServerFrame(
        final: Bool = true,
        masked: Bool = false,
        opcode: UInt8,
        payload: Data,
        to descriptor: Int32
    ) {
        var frame = Data([(final ? 0x80 : 0) | opcode])
        if payload.count < 126 {
            frame.append((masked ? 0x80 : 0) | UInt8(payload.count))
        } else {
            precondition(payload.count <= Int(UInt16.max))
            frame.append((masked ? 0x80 : 0) | 126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        }
        if masked {
            let mask: [UInt8] = [1, 2, 3, 4]
            frame.append(contentsOf: mask)
            frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        } else {
            frame.append(payload)
        }
        writeAll(frame, to: descriptor)
    }

    private func readExact(_ descriptor: Int32, count: Int) -> Data? {
        var data = Data()
        while data.count < count {
            var buffer = [UInt8](repeating: 0, count: count - data.count)
            let readCount = Darwin.read(descriptor, &buffer, buffer.count)
            guard readCount > 0 else { return nil }
            data.append(buffer, count: readCount)
        }
        return data
    }

    private func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { return }
                offset += count
            }
        }
    }
}
