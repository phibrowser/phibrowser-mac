// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
import Darwin
import Foundation

enum ServiceBrokerWebSocketError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidResponse
    case connectionClosed
    case protocolError
    case cancelled
}

final class ServiceBrokerWebSocket: @unchecked Sendable {
    private static let maximumHeaderBytes = 64 * 1024
    private static let webSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private let socketPath: String
    private let maximumMessageBytes: Int
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let receiveLock = NSLock()
    private var fileDescriptor: Int32 = -1
    private var buffered = Data()
    private var connected = false
    private var closed = false
    private var closeSent = false
    private var fragmentedOpcode: UInt8?
    private var fragmentedPayload = Data()

    init(socketPath: String, maximumMessageBytes: Int) {
        self.socketPath = socketPath
        self.maximumMessageBytes = maximumMessageBytes
    }

    deinit {
        closeDescriptor()
    }

    var source: BrokerWebSocketSource {
        BrokerWebSocketSource(
            send: { [self] frame in try await send(frame) },
            receive: { [self] in try await receive() },
            close: { [self] code, reason in await close(code: code, reason: reason) }
        )
    }

    func connect(path: String, headers: [String: String]) async throws {
        try await Self.runBlocking { [self] in
            guard maximumMessageBytes > 0 else { throw ServiceBrokerWebSocketError.invalidRequest }
            let target = try normalizedTarget(path)
            let key = makeClientKey()
            try connectSocket()
            do {
                try writeAll(try serializeHandshake(target: target, key: key, headers: headers))
                try validateHandshake(key: key)
                stateLock.lock()
                connected = true
                stateLock.unlock()
            } catch {
                closeDescriptor()
                throw error
            }
        }
    }

    func send(_ frame: BrokerWebSocketFrame) async throws {
        try await Self.runBlocking { [self] in
            guard frame.data.count <= maximumMessageBytes else {
                try failProtocol(code: 1009)
            }
            let opcode: UInt8
            switch frame.kind {
            case .text:
                guard String(data: frame.data, encoding: .utf8) != nil else {
                    try failProtocol(code: 1007)
                }
                opcode = 0x1
            case .binary:
                opcode = 0x2
            }
            try sendFrame(opcode: opcode, payload: frame.data)
        }
    }

    func receive() async throws -> BrokerWebSocketEvent {
        try await Self.runBlocking { [self] in
            receiveLock.lock()
            defer { receiveLock.unlock() }
            while true {
                let frame = try readFrame()
                if frame.isControl {
                    switch frame.opcode {
                    case 0x8:
                        let close = try parseClose(frame.payload)
                        if !isCloseSent {
                            try sendFrame(opcode: 0x8, payload: frame.payload)
                            markCloseSent()
                        }
                        closeDescriptor()
                        return .close(code: close.code, reason: close.reason)
                    case 0x9:
                        try sendFrame(opcode: 0xA, payload: frame.payload)
                        continue
                    case 0xA:
                        continue
                    default:
                        try failProtocol()
                    }
                }

                switch frame.opcode {
                case 0x0:
                    guard let opcode = fragmentedOpcode else { try failProtocol() }
                    guard fragmentedPayload.count <= maximumMessageBytes - frame.payload.count else {
                        try failProtocol(code: 1009)
                    }
                    fragmentedPayload.append(frame.payload)
                    guard frame.final else { continue }
                    let payload = fragmentedPayload
                    fragmentedOpcode = nil
                    fragmentedPayload.removeAll(keepingCapacity: false)
                    return try messageEvent(opcode: opcode, payload: payload)
                case 0x1, 0x2:
                    guard fragmentedOpcode == nil else { try failProtocol() }
                    if frame.final {
                        return try messageEvent(opcode: frame.opcode, payload: frame.payload)
                    }
                    fragmentedOpcode = frame.opcode
                    fragmentedPayload = frame.payload
                default:
                    try failProtocol()
                }
            }
        }
    }

    func close(code: UInt16?, reason: String?) async {
        _ = try? await Self.runBlocking { [self] in
            let payload = try closePayload(code: code, reason: reason)
            if isConnected && !isCloseSent {
                try sendFrame(opcode: 0x8, payload: payload)
                markCloseSent()
            }
            closeDescriptor()
        }
    }

    private static func expectedAccept(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + webSocketGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    private var isConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connected && !closed && fileDescriptor >= 0
    }

    private var isCloseSent: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closeSent
    }

    private func markCloseSent() {
        stateLock.lock()
        closeSent = true
        stateLock.unlock()
    }

    private func normalizedTarget(_ path: String) throws -> String {
        guard path == "/ws/phi-agent/execute" else {
            throw ServiceBrokerWebSocketError.invalidRequest
        }
        return "/phi-agent\(path)"
    }

    private func makeClientKey() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
    }

    private func serializeHandshake(
        target: String,
        key: String,
        headers suppliedHeaders: [String: String]
    ) throws -> Data {
        let reserved = Set([
            "connection", "content-length", "host", "keep-alive", "proxy-authenticate",
            "proxy-authorization", "sec-websocket-accept", "sec-websocket-extensions",
            "sec-websocket-key", "sec-websocket-protocol", "sec-websocket-version", "te",
            "trailer", "transfer-encoding", "upgrade"
        ])
        var headers = [String: String]()
        for (rawName, value) in suppliedHeaders {
            let name = rawName.lowercased()
            guard Self.isToken(name), !Self.containsControlCharacters(value), !reserved.contains(name) else {
                throw ServiceBrokerWebSocketError.invalidRequest
            }
            headers[name] = value
        }
        headers["host"] = "service-broker"
        headers["upgrade"] = "websocket"
        headers["connection"] = "Upgrade"
        headers["sec-websocket-key"] = key
        headers["sec-websocket-version"] = "13"

        var request = "GET \(target) HTTP/1.1\r\n"
        for name in headers.keys.sorted() {
            request += "\(name): \(headers[name]!)\r\n"
        }
        request += "\r\n"
        return Data(request.utf8)
    }

    private func validateHandshake(key: String) throws {
        let headerData = try readThroughHeaderTerminator()
        guard let header = String(data: headerData, encoding: .utf8) else {
            throw ServiceBrokerWebSocketError.invalidResponse
        }
        let lines = header.components(separatedBy: "\r\n")
        guard let statusLine = lines.first,
              !Self.containsControlCharacters(statusLine),
              statusLine.split(separator: " ", maxSplits: 2).prefix(2).map(String.init) == ["HTTP/1.1", "101"] else {
            throw ServiceBrokerWebSocketError.invalidResponse
        }
        var headers = [String: String]()
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw ServiceBrokerWebSocketError.invalidResponse
            }
            let name = String(line[..<colon]).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard Self.isToken(name), !Self.containsControlCharacters(value), headers[name] == nil else {
                throw ServiceBrokerWebSocketError.invalidResponse
            }
            headers[name] = value
        }
        guard headers["upgrade"]?.caseInsensitiveCompare("websocket") == .orderedSame,
              Self.headerTokens(headers["connection"]).contains("upgrade"),
              headers["sec-websocket-accept"] == Self.expectedAccept(for: key) else {
            throw ServiceBrokerWebSocketError.invalidResponse
        }
    }

    private func connectSocket() throws {
        stateLock.lock()
        let mayConnect = fileDescriptor < 0 && !closed
        stateLock.unlock()
        guard mayConnect else { throw ServiceBrokerWebSocketError.invalidRequest }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ServiceBrokerWebSocketError.connectionClosed }
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
            Darwin.close(descriptor)
            throw ServiceBrokerWebSocketError.connectionClosed
        }
        var noSigPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let encodedPath = Array(socketPath.utf8)
        guard encodedPath.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            throw ServiceBrokerWebSocketError.invalidRequest
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            encodedPath.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 && errno != EINPROGRESS {
            Darwin.close(descriptor)
            throw ServiceBrokerWebSocketError.connectionClosed
        }
        if result != 0 {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            guard Darwin.poll(&pollDescriptor, 1, 10_000) > 0 else {
                Darwin.close(descriptor)
                throw ServiceBrokerWebSocketError.connectionClosed
            }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                  socketError == 0 else {
                Darwin.close(descriptor)
                throw ServiceBrokerWebSocketError.connectionClosed
            }
        }

        stateLock.lock()
        if closed || fileDescriptor >= 0 {
            stateLock.unlock()
            Darwin.close(descriptor)
            throw ServiceBrokerWebSocketError.cancelled
        }
        fileDescriptor = descriptor
        stateLock.unlock()
    }

    private func readThroughHeaderTerminator() throws -> Data {
        let delimiter = Data("\r\n\r\n".utf8)
        var data = Data()
        while data.range(of: delimiter) == nil {
            guard let chunk = try readRaw(maxBytes: 4 * 1024) else {
                throw ServiceBrokerWebSocketError.connectionClosed
            }
            data.append(chunk)
            guard data.count <= Self.maximumHeaderBytes else {
                throw ServiceBrokerWebSocketError.invalidResponse
            }
        }
        let range = data.range(of: delimiter)!
        let header = Data(data[..<range.lowerBound])
        let remainder = data[range.upperBound...]
        if !remainder.isEmpty {
            stateLock.lock()
            buffered.append(contentsOf: remainder)
            stateLock.unlock()
        }
        return header
    }

    private func readFrame() throws -> RawFrame {
        let header = [UInt8](try readExact(2))
        let final = header[0] & 0x80 != 0
        let reservedBits = header[0] & 0x70
        let opcode = header[0] & 0x0F
        let masked = header[1] & 0x80 != 0
        guard reservedBits == 0, !masked else { try failProtocol() }

        let isControl = opcode & 0x08 != 0
        var payloadLength = UInt64(header[1] & 0x7F)
        if payloadLength == 126 {
            let extended = [UInt8](try readExact(2))
            payloadLength = UInt64(extended[0]) << 8 | UInt64(extended[1])
            guard payloadLength >= 126 else { try failProtocol() }
        } else if payloadLength == 127 {
            let extended = [UInt8](try readExact(8))
            guard extended[0] & 0x80 == 0 else { try failProtocol() }
            payloadLength = extended.reduce(0) { ($0 << 8) | UInt64($1) }
            guard payloadLength >= 65_536 else { try failProtocol() }
        }
        guard !isControl || (final && payloadLength <= 125),
              payloadLength <= UInt64(maximumMessageBytes),
              payloadLength <= UInt64(Int.max) else {
            try failProtocol(code: payloadLength > UInt64(maximumMessageBytes) ? 1009 : 1002)
        }
        return RawFrame(
            final: final,
            opcode: opcode,
            isControl: isControl,
            payload: try readExact(Int(payloadLength))
        )
    }

    private func messageEvent(opcode: UInt8, payload: Data) throws -> BrokerWebSocketEvent {
        switch opcode {
        case 0x1:
            guard String(data: payload, encoding: .utf8) != nil else { try failProtocol(code: 1007) }
            return .frame(BrokerWebSocketFrame(kind: .text, data: payload))
        case 0x2:
            return .frame(BrokerWebSocketFrame(kind: .binary, data: payload))
        default:
            try failProtocol()
        }
    }

    private func parseClose(_ payload: Data) throws -> (code: UInt16?, reason: String?) {
        guard payload.count != 1 else { try failProtocol() }
        guard payload.count >= 2 else { return (nil, nil) }
        let bytes = [UInt8](payload)
        let code = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        guard Self.isValidCloseCode(code) else { try failProtocol() }
        let reasonData = Data(bytes.dropFirst(2))
        guard let reason = String(data: reasonData, encoding: .utf8) else { try failProtocol(code: 1007) }
        return (code, reason.isEmpty ? nil : reason)
    }

    private func closePayload(code: UInt16?, reason: String?) throws -> Data {
        guard code != nil || reason == nil else { throw ServiceBrokerWebSocketError.invalidRequest }
        guard let code else { return Data() }
        guard Self.isValidCloseCode(code) else { throw ServiceBrokerWebSocketError.invalidRequest }
        let reasonData = Data((reason ?? "").utf8)
        guard reasonData.count <= 123 else { throw ServiceBrokerWebSocketError.invalidRequest }
        var payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
        payload.append(reasonData)
        return payload
    }

    private func sendFrame(opcode: UInt8, payload: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard isConnected else {
            throw ServiceBrokerWebSocketError.cancelled
        }
        var generator = SystemRandomNumberGenerator()
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(0x80 | 126)
            let length = UInt16(payload.count)
            frame.append(UInt8(length >> 8))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(0x80 | 127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(contentsOf: mask)
        var encoded = [UInt8](payload)
        for index in encoded.indices { encoded[index] ^= mask[index % 4] }
        frame.append(contentsOf: encoded)
        try writeAll(frame)
    }

    private func failProtocol(code: UInt16 = 1002) throws -> Never {
        if isConnected && !isCloseSent {
            let payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
            try? sendFrame(opcode: 0x8, payload: payload)
            markCloseSent()
        }
        closeDescriptor()
        throw ServiceBrokerWebSocketError.protocolError
    }

    private func readExact(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try readRaw(maxBytes: count - data.count) else {
                throw ServiceBrokerWebSocketError.connectionClosed
            }
            data.append(chunk)
        }
        return data
    }

    private func readRaw(maxBytes: Int) throws -> Data? {
        stateLock.lock()
        if !buffered.isEmpty {
            let count = min(maxBytes, buffered.count)
            let result = Data(buffered.prefix(count))
            buffered.removeFirst(count)
            stateLock.unlock()
            return result
        }
        let descriptor = fileDescriptor
        let isClosed = closed
        stateLock.unlock()
        guard !isClosed, descriptor >= 0 else { throw ServiceBrokerWebSocketError.cancelled }

        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        while Darwin.poll(&pollDescriptor, 1, 100) == 0 {
            stateLock.lock()
            let shouldStop = closed || fileDescriptor != descriptor
            stateLock.unlock()
            if shouldStop { throw ServiceBrokerWebSocketError.cancelled }
        }
        guard pollDescriptor.revents & Int16(POLLERR | POLLNVAL) == 0 else {
            throw ServiceBrokerWebSocketError.connectionClosed
        }
        var bytes = [UInt8](repeating: 0, count: maxBytes)
        let count = Darwin.read(descriptor, &bytes, maxBytes)
        if count == 0 { return nil }
        if count < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { return try readRaw(maxBytes: maxBytes) }
            throw ServiceBrokerWebSocketError.connectionClosed
        }
        return Data(bytes.prefix(count))
    }

    private func writeAll(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            stateLock.lock()
            let descriptor = fileDescriptor
            let isClosed = closed
            stateLock.unlock()
            guard !isClosed, descriptor >= 0 else { throw ServiceBrokerWebSocketError.cancelled }
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                guard Darwin.poll(&pollDescriptor, 1, 10_000) > 0 else {
                    throw ServiceBrokerWebSocketError.connectionClosed
                }
            } else {
                throw ServiceBrokerWebSocketError.connectionClosed
            }
        }
    }

    private func closeDescriptor() {
        stateLock.lock()
        closed = true
        connected = false
        let descriptor = fileDescriptor
        fileDescriptor = -1
        buffered.removeAll(keepingCapacity: false)
        stateLock.unlock()
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    private static func runBlocking<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }

    private static func headerTokens(_ value: String?) -> Set<String> {
        Set(value?.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? [])
    }

    private static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            $0.value > 0x20 && $0.value < 0x7F && !"()<>@,;:\\\"/[]?={} \t".unicodeScalars.contains($0)
        }
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func isValidCloseCode(_ code: UInt16) -> Bool {
        switch code {
        case 1000...1003, 1007...1014, 3000...4999:
            return true
        default:
            return false
        }
    }
}

private struct RawFrame {
    let final: Bool
    let opcode: UInt8
    let isControl: Bool
    let payload: Data
}
