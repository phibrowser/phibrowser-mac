// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import Foundation

final class ServiceBrokerHTTPConnection: @unchecked Sendable {
    private static let maximumHeaderBytes = 64 * 1024

    private let socketPath: String
    private let bodyLimit: Int?
    private let peerAuthenticator: ServiceBrokerPeerAuthenticator
    fileprivate let ioTimeoutMilliseconds: Int
    private let stateLock = NSLock()
    private var fileDescriptor: Int32 = -1
    private var buffered = Data()
    private var closed = false

    init(
        socketPath: String,
        bodyLimit: Int? = nil,
        peerAuthenticator: ServiceBrokerPeerAuthenticator = .production,
        ioTimeoutMilliseconds: Int = 30_000
    ) {
        self.socketPath = socketPath
        self.bodyLimit = bodyLimit
        self.peerAuthenticator = peerAuthenticator
        self.ioTimeoutMilliseconds = max(1, ioTimeoutMilliseconds)
    }

    deinit {
        close()
    }

    func execute(_ request: BrokerHTTPRequest) async throws -> BrokerHTTPStream {
        try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw ServiceBrokerHTTPError.cancelled }
            do {
                let stream = try await Self.runBlocking(
                    timeoutMilliseconds: ioTimeoutMilliseconds
                ) { [self] deadline in
                    try connectIfNeeded(deadline: deadline)
                    try writeAll(try serialize(request), deadline: deadline)
                    let parsed = try readResponseHead(deadline: deadline)
                    return BrokerHTTPStream(
                        response: BrokerHTTPResponseHead(
                            statusCode: parsed.statusCode,
                            headers: parsed.headers
                        ),
                        framing: parsed.framing,
                        connection: self,
                        bodyLimit: bodyLimit
                    )
                }
                guard !Task.isCancelled else {
                    close()
                    throw ServiceBrokerHTTPError.cancelled
                }
                return stream
            } catch {
                close()
                if Task.isCancelled { throw ServiceBrokerHTTPError.cancelled }
                throw error
            }
        } onCancel: {
            self.close()
        }
    }

    func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        closed = true
        guard fileDescriptor >= 0 else { return }
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
        buffered.removeAll(keepingCapacity: false)
    }

    fileprivate func readRaw(maxBytes: Int, deadline: ServiceBrokerDeadline) throws -> Data? {
        guard maxBytes > 0 else { throw ServiceBrokerHTTPError.invalidRequest }

        stateLock.lock()
        if !buffered.isEmpty {
            let count = min(maxBytes, buffered.count)
            let result = buffered.prefix(count)
            buffered.removeFirst(count)
            stateLock.unlock()
            return result
        }
        let descriptor = fileDescriptor
        let isClosed = closed
        stateLock.unlock()

        guard !isClosed, descriptor >= 0 else { throw ServiceBrokerHTTPError.cancelled }
        try waitForIO(descriptor: descriptor, events: Int16(POLLIN), deadline: deadline)

        var bytes = [UInt8](repeating: 0, count: maxBytes)
        let count = Darwin.read(descriptor, &bytes, maxBytes)
        if count == 0 { return nil }
        if count < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return try readRaw(maxBytes: maxBytes, deadline: deadline)
            }
            throw ServiceBrokerHTTPError.connectionClosed
        }
        return Data(bytes.prefix(count))
    }

    private func connectIfNeeded(deadline: ServiceBrokerDeadline) throws {
        stateLock.lock()
        let existing = fileDescriptor
        stateLock.unlock()
        if existing >= 0 { return }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ServiceBrokerHTTPError.connectionClosed }
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
            Darwin.close(descriptor)
            throw ServiceBrokerHTTPError.connectionClosed
        }
        var noSigPipe: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            Darwin.close(descriptor)
            throw ServiceBrokerHTTPError.connectionClosed
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let encodedPath = Array(socketPath.utf8)
        guard encodedPath.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            throw ServiceBrokerHTTPError.invalidRequest
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            encodedPath.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 && errno != EINPROGRESS {
            Darwin.close(descriptor)
            throw ServiceBrokerHTTPError.connectionClosed
        }
        if result != 0 {
            do {
                try waitForIO(descriptor: descriptor, events: Int16(POLLOUT), deadline: deadline)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else {
                Darwin.close(descriptor)
                throw ServiceBrokerHTTPError.connectionClosed
            }
        }

        do {
            try peerAuthenticator.authenticate(fileDescriptor: descriptor)
        } catch {
            Darwin.close(descriptor)
            throw ServiceBrokerHTTPError.peerAuthentication
        }

        stateLock.lock()
        if closed || fileDescriptor >= 0 {
            stateLock.unlock()
            Darwin.close(descriptor)
            throw ServiceBrokerHTTPError.cancelled
        }
        fileDescriptor = descriptor
        stateLock.unlock()
    }

    private func writeAll(_ data: Data, deadline: ServiceBrokerDeadline) throws {
        var offset = 0
        while offset < data.count {
            guard deadline.pollTimeoutMilliseconds() != nil else {
                throw ServiceBrokerHTTPError.timedOut
            }
            stateLock.lock()
            let descriptor = fileDescriptor
            let isClosed = closed
            stateLock.unlock()
            guard !isClosed, descriptor >= 0 else { throw ServiceBrokerHTTPError.cancelled }

            let written = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                try waitForIO(descriptor: descriptor, events: Int16(POLLOUT), deadline: deadline)
                continue
            }
            throw ServiceBrokerHTTPError.connectionClosed
        }
    }

    private func serialize(_ request: BrokerHTTPRequest) throws -> Data {
        guard isToken(request.method), let path = normalizedPath(request.path) else {
            throw ServiceBrokerHTTPError.invalidRequest
        }
        let hopByHop = hopByHopHeaders(from: request.headers)
        var headers = [String: String]()
        for entry in request.headers {
            let name = entry.key.lowercased()
            guard isToken(name), !containsControlCharacters(entry.value) else {
                throw ServiceBrokerHTTPError.invalidRequest
            }
            if !hopByHop.contains(name) {
                headers[name] = entry.value
            }
        }
        headers.removeValue(forKey: "content-length")
        headers.removeValue(forKey: "host")
        headers["host"] = "service-broker"
        if let body = request.body {
            headers["content-length"] = String(body.count)
        }
        headers["connection"] = "close"

        var serialized = "\(request.method) /\(request.service.rawValue)\(path) HTTP/1.1\r\n"
        for name in headers.keys.sorted() {
            serialized += "\(name): \(headers[name]!)\r\n"
        }
        serialized += "\r\n"
        var data = Data(serialized.utf8)
        if let body = request.body { data.append(body) }
        return data
    }

    private func normalizedPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              !containsControlCharacters(path),
              !path.lowercased().contains("://") else {
            return nil
        }
        let pathname = String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard let decodedPath = pathname.removingPercentEncoding,
              !containsControlCharacters(decodedPath),
              !decodedPath.lowercased().contains("://") else {
            return nil
        }
        let components = decodedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("."), !components.contains(".."), components.first != "broker" else {
            return nil
        }
        return path
    }

    private func hopByHopHeaders(from headers: [String: String]) -> Set<String> {
        let connectionTokens = headers.first { $0.key.caseInsensitiveCompare("connection") == .orderedSame }
            .map { $0.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } } ?? []
        return Set([
            "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
            "te", "trailer", "transfer-encoding", "upgrade"
        ] + connectionTokens)
    }

    private func readResponseHead(deadline: ServiceBrokerDeadline) throws -> ParsedResponseHead {
        var response = Data()
        let delimiter = Data("\r\n\r\n".utf8)
        while response.range(of: delimiter) == nil {
            guard let chunk = try readRaw(maxBytes: 4 * 1024, deadline: deadline) else {
                throw ServiceBrokerHTTPError.connectionClosed
            }
            response.append(chunk)
            guard response.count <= Self.maximumHeaderBytes else {
                throw ServiceBrokerHTTPError.invalidResponse
            }
        }

        let range = response.range(of: delimiter)!
        let headData = response[..<range.lowerBound]
        let remainder = response[range.upperBound...]
        if !remainder.isEmpty {
            stateLock.lock()
            buffered.insert(contentsOf: remainder, at: 0)
            stateLock.unlock()
        }
        guard let head = String(data: headData, encoding: .utf8) else {
            throw ServiceBrokerHTTPError.invalidResponse
        }
        return try ParsedResponseHead(head)
    }

    private func waitForIO(
        descriptor: Int32,
        events: Int16,
        deadline: ServiceBrokerDeadline
    ) throws {
        while true {
            stateLock.lock()
            let isClosed = closed
            stateLock.unlock()
            guard !isClosed else { throw ServiceBrokerHTTPError.cancelled }
            guard let timeout = deadline.pollTimeoutMilliseconds() else {
                throw ServiceBrokerHTTPError.timedOut
            }
            var polled = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&polled, 1, timeout)
            if result > 0 {
                guard polled.revents & Int16(POLLERR | POLLNVAL) == 0 else {
                    throw ServiceBrokerHTTPError.connectionClosed
                }
                return
            }
            if result < 0, errno != EINTR {
                throw ServiceBrokerHTTPError.connectionClosed
            }
        }
    }

    fileprivate static func runBlocking<T: Sendable>(
        timeoutMilliseconds: Int,
        _ operation: @escaping @Sendable (ServiceBrokerDeadline) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try operation(ServiceBrokerDeadline(
                        timeoutMilliseconds: timeoutMilliseconds
                    )))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

final class BrokerHTTPStream: @unchecked Sendable {
    let response: BrokerHTTPResponseHead

    private let connection: ServiceBrokerHTTPConnection
    private let bodyLimit: Int?
    private let lock = NSLock()
    private var framing: BrokerHTTPBodyFraming
    private var bytesRead = 0
    private var chunkBytesRemaining: Int?
    private var needsChunkTerminator = false
    private var completed = false

    fileprivate init(
        response: BrokerHTTPResponseHead,
        framing: BrokerHTTPBodyFraming,
        connection: ServiceBrokerHTTPConnection,
        bodyLimit: Int?
    ) {
        self.response = response
        self.framing = framing
        self.connection = connection
        self.bodyLimit = bodyLimit
    }

    deinit {
        cancel()
    }

    func read(maxBytes: Int) async throws -> Data? {
        try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw ServiceBrokerHTTPError.cancelled }
            do {
                let data = try await ServiceBrokerHTTPConnection.runBlocking(
                    timeoutMilliseconds: connection.ioTimeoutMilliseconds
                ) { [self] deadline in
                    try readSynchronously(maxBytes: maxBytes, deadline: deadline)
                }
                guard !Task.isCancelled else {
                    cancel()
                    throw ServiceBrokerHTTPError.cancelled
                }
                return data
            } catch {
                if Task.isCancelled { throw ServiceBrokerHTTPError.cancelled }
                if error as? ServiceBrokerHTTPError == .timedOut {
                    cancel()
                }
                throw error
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        connection.close()
    }

    private func readSynchronously(maxBytes: Int, deadline: ServiceBrokerDeadline) throws -> Data? {
        guard maxBytes > 0 else { throw ServiceBrokerHTTPError.invalidRequest }
        let boundedMaxBytes = min(maxBytes, 64 * 1024)
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return nil }

        switch framing {
        case .none:
            completed = true
            return nil
        case .fixedLength(let remaining):
            guard remaining > 0 else {
                completed = true
                return nil
            }
            guard let data = try connection.readRaw(
                maxBytes: min(boundedMaxBytes, remaining),
                deadline: deadline
            ) else {
                throw ServiceBrokerHTTPError.connectionClosed
            }
            framing = .fixedLength(remaining - data.count)
            try record(data)
            return data
        case .eofDelimited:
            guard let data = try connection.readRaw(maxBytes: boundedMaxBytes, deadline: deadline) else {
                completed = true
                return nil
            }
            try record(data)
            return data
        case .chunked:
            return try readChunked(maxBytes: boundedMaxBytes, deadline: deadline)
        }
    }

    private func readChunked(maxBytes: Int, deadline: ServiceBrokerDeadline) throws -> Data? {
        while true {
            if let remaining = chunkBytesRemaining, remaining > 0 {
                guard let data = try connection.readRaw(
                    maxBytes: min(maxBytes, remaining),
                    deadline: deadline
                ) else {
                    throw ServiceBrokerHTTPError.connectionClosed
                }
                chunkBytesRemaining = remaining - data.count
                needsChunkTerminator = chunkBytesRemaining == 0
                try record(data)
                return data
            }
            if needsChunkTerminator {
                guard try readExact(2, deadline: deadline) == Data("\r\n".utf8) else {
                    throw ServiceBrokerHTTPError.invalidResponse
                }
                needsChunkTerminator = false
                chunkBytesRemaining = nil
            }
            let line = try readLine(deadline: deadline)
            let sizeText = line.split(separator: ";", maxSplits: 1).first ?? ""
            guard !sizeText.isEmpty, sizeText.allSatisfy({ $0.isHexDigit }), let size = Int(sizeText, radix: 16) else {
                throw ServiceBrokerHTTPError.invalidResponse
            }
            if size == 0 {
                while !(try readLine(deadline: deadline)).isEmpty {}
                completed = true
                return nil
            }
            if let bodyLimit, (size > bodyLimit || bytesRead > bodyLimit - size) {
                throw ServiceBrokerHTTPError.responseTooLarge
            }
            chunkBytesRemaining = size
        }
    }

    private func readLine(deadline: ServiceBrokerDeadline) throws -> String {
        var data = Data()
        while true {
            guard let byte = try connection.readRaw(maxBytes: 1, deadline: deadline) else {
                throw ServiceBrokerHTTPError.connectionClosed
            }
            data.append(byte)
            guard data.count <= 8 * 1024 else { throw ServiceBrokerHTTPError.invalidResponse }
            if data.suffix(2) == Data("\r\n".utf8) {
                data.removeLast(2)
                guard let line = String(data: data, encoding: .utf8), !line.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                    throw ServiceBrokerHTTPError.invalidResponse
                }
                return line
            }
        }
    }

    private func readExact(_ count: Int, deadline: ServiceBrokerDeadline) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try connection.readRaw(
                maxBytes: count - data.count,
                deadline: deadline
            ) else {
                throw ServiceBrokerHTTPError.connectionClosed
            }
            data.append(chunk)
        }
        return data
    }

    private func record(_ data: Data) throws {
        if let bodyLimit, (data.count > bodyLimit || bytesRead > bodyLimit - data.count) {
            throw ServiceBrokerHTTPError.responseTooLarge
        }
        bytesRead += data.count
    }
}

private enum BrokerHTTPBodyFraming: Sendable {
    case none
    case fixedLength(Int)
    case chunked
    case eofDelimited
}

private struct ParsedResponseHead {
    let statusCode: Int
    let headers: [BrokerHTTPHeader]
    let framing: BrokerHTTPBodyFraming

    init(_ raw: String) throws {
        let lines = raw.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw ServiceBrokerHTTPError.invalidResponse }
        guard !containsControlCharacters(statusLine) else {
            throw ServiceBrokerHTTPError.invalidResponse
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2,
              statusParts[0] == "HTTP/1.1" || statusParts[0] == "HTTP/1.0",
              statusParts[1].count == 3,
              let parsedStatus = Int(statusParts[1]), (100...599).contains(parsedStatus) else {
            throw ServiceBrokerHTTPError.invalidResponse
        }
        statusCode = parsedStatus

        var parsedHeaders = [BrokerHTTPHeader]()
        var contentLengths = [String]()
        var transferEncodings = [String]()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw ServiceBrokerHTTPError.invalidResponse }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard isToken(name), !containsControlCharacters(value) else {
                throw ServiceBrokerHTTPError.invalidResponse
            }
            parsedHeaders.append(BrokerHTTPHeader(name: name, value: value))
            if name == "content-length" { contentLengths.append(value) }
            if name == "transfer-encoding" { transferEncodings.append(value.lowercased()) }
        }
        headers = parsedHeaders

        guard transferEncodings.count <= 1, contentLengths.count <= 1 else {
            throw ServiceBrokerHTTPError.invalidResponse
        }
        let contentLength: Int?
        if let rawContentLength = contentLengths.first {
            guard !rawContentLength.isEmpty,
                  rawContentLength.allSatisfy({ $0.isNumber }),
                  let parsedContentLength = Int(rawContentLength) else {
                throw ServiceBrokerHTTPError.invalidResponse
            }
            contentLength = parsedContentLength
        } else {
            contentLength = nil
        }
        if let transferEncoding = transferEncodings.first {
            guard contentLength == nil, transferEncoding == "chunked" else {
                throw ServiceBrokerHTTPError.invalidResponse
            }
        }

        if (100...199).contains(statusCode) || statusCode == 204 || statusCode == 304 {
            framing = .none
        } else if transferEncodings.first != nil {
            framing = .chunked
        } else if let contentLength {
            framing = .fixedLength(contentLength)
        } else {
            framing = .eofDelimited
        }
    }
}

private func isToken(_ value: String) -> Bool {
    !value.isEmpty && value.unicodeScalars.allSatisfy {
        $0.value > 0x20 && $0.value < 0x7F && !"()<>@,;:\\\"/[]?={} \t".unicodeScalars.contains($0)
    }
}

private func containsControlCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
}
