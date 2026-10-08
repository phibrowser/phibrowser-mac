// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
import Darwin
import Foundation

/// An app-owned DevTools (CDP) client session on one page target.
///
/// The in-app autofill dispatch (`credentials.autofill`) must act on a page
/// WITHOUT handing the secret to the agent that asked — so Phi itself has to
/// be the CDP client. This opens a `socketpair()`, hands one end to Chromium's
/// DevTools server through the same FD-injection transport agent connections
/// use (`attachDevToolsConnectionWithFD:`), performs the WebSocket upgrade to
/// `/devtools/page/<targetId>` as a client, and speaks JSON CDP commands over
/// it. No listener, no port, no consent prompt: both ends of the pair live and
/// die inside the app+browser pair, unreachable from outside.
///
/// The mirror image of `AgentDirectConnection` (where the app is the
/// WebSocket *server* for agents): here the app is the *client*, so outbound
/// frames are masked and inbound frames arrive unmasked (RFC 6455 §5.1).
///
/// One instance = one connection = one page session. Commands are sent one at
/// a time from a single async caller; CDP events are discarded (nothing here
/// subscribes). Call `close()` when done — deinit does not tear down.
/// `@unchecked Sendable`: all mutable state is confined to `queue`.
final class AppDevToolsPageSession: @unchecked Sendable {

    enum SessionError: Error {
        /// The bridge is absent or the DevTools injection transport is not
        /// running (early startup) — the capability is unavailable.
        case transportUnavailable
        /// The server refused the WebSocket upgrade — in practice a bad or
        /// stale page target id.
        case upgradeFailed
        /// The CDP reply carried an error object.
        case commandFailed(String)
        case timedOut
        /// The connection died (or broke protocol) mid-exchange.
        case connectionClosed
    }

    private let fd: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var handshakeDone = false
    private var closed = false
    private var fragOpcode: UInt8 = 0
    private var fragData = Data()
    private var secWebSocketKey = ""

    private var nextCommandId = 1
    // Single-flight by design: the one caller awaits each command in turn.
    private var pending: (id: Int, cont: CheckedContinuation<[String: Any], Error>)?
    private var handshakeCont: CheckedContinuation<Void, Error>?
    private var timeoutItem: DispatchWorkItem?

    private static let wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    private let maxMessageBytes: Int

    /// How long one write may wait for a DevTools server that has stopped
    /// reading. Shorter than the agent channel's equivalent: the peer here is
    /// the browser's own server across an in-app socketpair, so a stall
    /// outlasting a couple of seconds means the session is finished, not busy.
    private static let writeStallTimeoutMs = 2_000

    /// Dials the browser's DevTools server and upgrades onto `targetId`'s page
    /// endpoint. Throws `transportUnavailable` when the bridge can't adopt the
    /// fd, `upgradeFailed` when the target doesn't exist.
    @MainActor
    static func open(targetId: String,
                     timeout: TimeInterval = 10,
                     maxMessageBytes: Int = 8 * 1024 * 1024) async throws -> AppDevToolsPageSession {
        try await dial(endpoint: "/devtools/page/\(targetId)", timeout: timeout,
                       maxMessageBytes: maxMessageBytes)
    }

    /// Dials the browser-level endpoint instead of a page's. Only the browser
    /// endpoint answers `Target.getTargets` / `Browser.getWindowForTarget`, so
    /// this is how the app resolves which page targets belong to one of its
    /// windows before attaching to them individually.
    ///
    /// Chromium namespaces that endpoint with a per-launch GUID
    /// (`/devtools/browser/<uuid>`); a bare `/devtools/browser` does NOT
    /// upgrade. The path is therefore discovered from `/json/version` first —
    /// the same handshake the phi-browser skill performs.
    @MainActor
    static func openBrowser(timeout: TimeInterval = 10) async throws -> AppDevToolsPageSession {
        // The GUID is fixed for the life of the browser process, so discovery
        // runs once rather than putting an HTTP round trip in front of every
        // caller. A stale path (browser relaunched) fails the upgrade, which
        // drops the cache and rediscovers.
        if let cached = cachedBrowserEndpoint {
            do {
                return try await dial(endpoint: cached, timeout: timeout)
            } catch {
                cachedBrowserEndpoint = nil
            }
        }
        let endpoint = try await browserEndpoint(timeout: timeout)
        let session = try await dial(endpoint: endpoint, timeout: timeout)
        cachedBrowserEndpoint = endpoint
        return session
    }

    @MainActor private static var cachedBrowserEndpoint: String?

    /// Reads `webSocketDebuggerUrl` from `/json/version` and keeps only its
    /// path: the transport is this app's socket pair, not the host:port the
    /// browser advertises there.
    @MainActor
    private static func browserEndpoint(timeout: TimeInterval) async throws -> String {
        let body = try await httpGet(path: "/json/version", timeout: timeout)
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let advertised = json["webSocketDebuggerUrl"] as? String,
              let path = URLComponents(string: advertised)?.path, !path.isEmpty else {
            throw SessionError.upgradeFailed
        }
        return path
    }

    /// One plain HTTP GET over a fresh injected fd. `Connection: close` lets the
    /// body end at EOF, so the small JSON the discovery endpoints return needs
    /// no chunked decoding.
    @MainActor
    private static func httpGet(path: String, timeout: TimeInterval) async throws -> Data {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw SessionError.transportUnavailable
        }
        let appFD = fds[0]
        let attached = ChromiumLauncher.sharedInstance().bridge?
            .attachDevToolsConnection(withFD: fds[1]) ?? false
        guard attached else {
            Darwin.close(appFD)
            throw SessionError.transportUnavailable
        }
        // Blocking socket IO, kept off the main thread.
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                defer { Darwin.close(appFD) }
                do {
                    cont.resume(returning:
                        try Self.exchange(fd: appFD, path: path, timeout: timeout))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func exchange(fd: Int32, path: String,
                                 timeout: TimeInterval) throws -> Data {
        let request = "GET \(path) HTTP/1.1\r\nHost: localhost\r\n" +
                      "Connection: close\r\n\r\n"
        let out = [UInt8](request.utf8)
        var sent = 0
        while sent < out.count {
            let written = out.withUnsafeBytes { raw -> Int in
                Darwin.write(fd, raw.baseAddress!.advanced(by: sent), out.count - sent)
            }
            guard written > 0 else { throw SessionError.connectionClosed }
            sent += written
        }

        let deadline = Date().addingTimeInterval(timeout)
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var bodyStart: Int?
        var expected: Int?

        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&descriptor, 1, remaining) > 0 else { break }
            let read = Darwin.read(fd, &chunk, chunk.count)
            if read < 0 { throw SessionError.connectionClosed }
            if read == 0 { break }  // EOF.
            response.append(contentsOf: chunk[0..<read])

            if bodyStart == nil,
               let separator = response.range(of: Data("\r\n\r\n".utf8)) {
                bodyStart = separator.upperBound
                expected = contentLength(
                    in: String(decoding: response[..<separator.lowerBound], as: UTF8.self))
            }
            // Chromium's DevTools HTTP server keeps the connection alive
            // whatever `Connection: close` asks for, so it never sends EOF —
            // waiting for one would burn the whole timeout on every call.
            // Content-Length is what actually ends the body.
            if let start = bodyStart, let length = expected,
               response.count - start >= length {
                return response.subdata(in: start..<(start + length))
            }
        }

        // No Content-Length (or the peer closed early): whatever arrived is it.
        guard let start = bodyStart else { throw SessionError.timedOut }
        return response.subdata(in: start..<response.endIndex)
    }

    private static func contentLength(in header: String) -> Int? {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                    == "content-length" else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    @MainActor
    private static func dial(endpoint: String,
                             timeout: TimeInterval,
                             maxMessageBytes: Int = 8 * 1024 * 1024) async throws -> AppDevToolsPageSession {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw SessionError.transportUnavailable
        }
        let appFD = fds[0]
        // The bridge ALWAYS takes ownership of its fd, attached or not.
        let attached = ChromiumLauncher.sharedInstance().bridge?
            .attachDevToolsConnection(withFD: fds[1]) ?? false
        guard attached else {
            Darwin.close(appFD)
            throw SessionError.transportUnavailable
        }
        let session = AppDevToolsPageSession(fd: appFD, maxMessageBytes: maxMessageBytes)
        try await session.upgrade(endpoint: endpoint, timeout: timeout)
        return session
    }

    private init(fd: Int32, maxMessageBytes: Int) {
        self.fd = fd
        self.maxMessageBytes = maxMessageBytes
        self.queue = DispatchQueue(label: "com.phibrowser.cdp.appsession.\(fd)")
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Sends one CDP command and returns its `result` object. Throws
    /// `commandFailed` when the server replies with a CDP error.
    func command(_ method: String, params: [String: Any] = [:],
                 timeout: TimeInterval = 15) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard !self.closed, self.pending == nil else {
                    cont.resume(throwing: SessionError.connectionClosed)
                    return
                }
                let id = self.nextCommandId
                self.nextCommandId += 1
                guard let data = try? JSONSerialization.data(withJSONObject:
                        ["id": id, "method": method, "params": params]) else {
                    cont.resume(throwing: SessionError.commandFailed("encode failed"))
                    return
                }
                self.pending = (id, cont)
                self.armTimeout(timeout)
                self.writeFrame(opcode: 0x1, payload: [UInt8](data))
            }
        }
    }

    func close() {
        queue.async { self.teardown() }
    }

    // MARK: - Handshake

    private func upgrade(endpoint: String, timeout: TimeInterval) async throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            .base64EncodedString()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                self.secWebSocketKey = key
                self.handshakeCont = cont
                self.armTimeout(timeout)
                self.startReadSource()
                self.writeRaw(
                    "GET \(endpoint) HTTP/1.1\r\n" +
                    "Host: localhost\r\n" +
                    "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
                    "Sec-WebSocket-Key: \(key)\r\n" +
                    "Sec-WebSocket-Version: 13\r\n\r\n")
            }
        }
    }

    private func startReadSource() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.onReadable() }
        let socketFD = fd
        source.setCancelHandler {
            Darwin.close(socketFD)
        }
        readSource = source
        source.resume()
    }

    /// Fails whichever exchange is outstanding when it doesn't complete in
    /// time, and drops the connection — a stuck page session has no second use.
    private func armTimeout(_ seconds: TimeInterval) {
        timeoutItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.fail(SessionError.timedOut)
        }
        timeoutItem = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Resumes any outstanding continuation with `error` and tears down.
    private func fail(_ error: SessionError) {
        if let cont = handshakeCont {
            handshakeCont = nil
            cont.resume(throwing: error)
        }
        if let p = pending {
            pending = nil
            p.cont.resume(throwing: error)
        }
        teardown()
    }

    private func teardown() {
        guard !closed else { return }
        closed = true
        timeoutItem?.cancel()
        timeoutItem = nil
        if let cont = handshakeCont {
            handshakeCont = nil
            cont.resume(throwing: SessionError.connectionClosed)
        }
        if let p = pending {
            pending = nil
            p.cont.resume(throwing: SessionError.connectionClosed)
        }
        if let readSource {
            readSource.cancel()          // cancel handler closes the fd
            self.readSource = nil
        } else {
            Darwin.close(fd)             // upgrade never started reading
        }
    }

    // MARK: - Reading

    private func onReadable() {
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                continue
            }
            if n == 0 { fail(.connectionClosed); return }   // peer closed
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            if errno == EINTR { continue }
            fail(.connectionClosed)
            return
        }
        if !handshakeDone {
            guard processUpgradeResponse() else { return }
        }
        drainFrames()
    }

    /// Validates the 101 response (status + Sec-WebSocket-Accept echo) and
    /// resumes the upgrade await. Anything else fails the session — the one
    /// expected non-101 answer is the server rejecting an unknown target id.
    private func processUpgradeResponse() -> Bool {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        buffer.removeSubrange(..<headerEnd.upperBound)

        let statusLine = header.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let accept = Self.headerValue("Sec-WebSocket-Accept", in: header)
        guard statusLine.contains(" 101 "), accept == Self.acceptKey(for: secWebSocketKey) else {
            fail(.upgradeFailed)
            return false
        }
        handshakeDone = true
        timeoutItem?.cancel()
        if let cont = handshakeCont {
            handshakeCont = nil
            cont.resume()
        }
        return true
    }

    private func drainFrames() {
        while true {
            guard buffer.count >= 2 else { return }
            let b0 = buffer[buffer.startIndex]
            let b1 = buffer[buffer.startIndex + 1]
            let fin = (b0 & 0x80) != 0
            let opcode = b0 & 0x0f
            let masked = (b1 & 0x80) != 0
            var len = Int(b1 & 0x7f)
            var offset = 2
            if len == 126 {
                guard buffer.count >= 4 else { return }
                len = Int(buffer[buffer.startIndex + 2]) << 8
                    | Int(buffer[buffer.startIndex + 3])
                offset = 4
            } else if len == 127 {
                guard buffer.count >= 10 else { return }
                var v: UInt64 = 0
                for i in 0..<8 { v = (v << 8) | UInt64(buffer[buffer.startIndex + 2 + i]) }
                guard v <= UInt64(maxMessageBytes) else { fail(.connectionClosed); return }
                len = Int(v)
                offset = 10
            }
            if len > maxMessageBytes { fail(.connectionClosed); return }
            // Server frames MUST NOT be masked (RFC 6455 §5.1).
            guard !masked else { fail(.connectionClosed); return }
            guard buffer.count >= offset + len else { return }
            let payloadStart = buffer.startIndex + offset
            let payload = [UInt8](buffer[payloadStart..<payloadStart + len])
            buffer.removeSubrange(buffer.startIndex..<(payloadStart + len))
            handleFrame(fin: fin, opcode: opcode, payload: payload)
        }
    }

    private func handleFrame(fin: Bool, opcode: UInt8, payload: [UInt8]) {
        switch opcode {
        case 0x8:                                   // close
            fail(.connectionClosed)
        case 0x9:                                   // ping -> pong
            writeFrame(opcode: 0xa, payload: payload)
        case 0xa:                                   // pong
            break
        case 0x0:                                   // continuation
            guard payload.count <= maxMessageBytes - fragData.count else {
                fail(.connectionClosed)
                return
            }
            fragData.append(contentsOf: payload)
            if fin { dispatchMessage(opcode: fragOpcode, data: fragData); fragData = Data() }
        default:                                    // text (0x1) / binary (0x2)
            if fin {
                dispatchMessage(opcode: opcode, data: Data(payload))
            } else {
                fragOpcode = opcode
                fragData = Data(payload)
            }
        }
    }

    private func dispatchMessage(opcode: UInt8, data: Data) {
        guard opcode == 0x1 else { return }         // CDP is JSON text only
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? Int else { return }  // events have no id — drop
        guard let p = pending, p.id == id else { return }
        pending = nil
        timeoutItem?.cancel()
        if let error = obj["error"] as? [String: Any] {
            p.cont.resume(throwing: SessionError.commandFailed(
                error["message"] as? String ?? "unknown CDP error"))
        } else {
            p.cont.resume(returning: obj["result"] as? [String: Any] ?? [:])
        }
    }

    // MARK: - Writing (on `queue`)

    /// Client frames are masked (RFC 6455 §5.1).
    private func writeFrame(opcode: UInt8, payload: [UInt8]) {
        guard !closed else { return }
        var frame = [UInt8]()
        frame.append(0x80 | opcode)
        let len = payload.count
        if len < 126 {
            frame.append(0x80 | UInt8(len))
        } else if len < 65536 {
            frame.append(0x80 | 126)
            frame.append(UInt8((len >> 8) & 0xff))
            frame.append(UInt8(len & 0xff))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len >> shift) & 0xff))
            }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        for (i, byte) in payload.enumerated() {
            frame.append(byte ^ mask[i & 3])
        }
        writeAll(frame)
    }

    private func writeRaw(_ text: String) {
        writeAll([UInt8](text.utf8))
    }

    private func writeAll(_ bytes: [UInt8]) {
        var offset = 0
        var completed = true
        bytes.withUnsafeBytes { raw in
            while offset < bytes.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK),
                   waitWritable() {
                    continue
                }
                completed = false
                break
            }
        }
        guard !completed else { return }
        // A frame's length prefix promises bytes that will now never arrive,
        // so the server would misread this frame and every one after it.
        // Failing the exchange reports that now; a silently truncated command
        // would strand the caller until its timeout on a connection that can
        // no longer carry a reply.
        fail(.connectionClosed)
    }

    /// Waits for the socket to accept more bytes.
    ///
    /// The fd is non-blocking for the read loop, so a command larger than the
    /// send buffer (8 KiB on a unix socket) hits EAGAIN partway through a
    /// frame — an autofill dispatch carrying a long selector will do it. This
    /// runs on the session's own serial queue, so the wait delays only this
    /// session. False means the server stopped reading for longer than a
    /// stalled peer is worth, or the socket failed.
    private func waitWritable() -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&descriptor, 1, Int32(Self.writeStallTimeoutMs))
        if ready > 0 {
            return (descriptor.revents & Int16(POLLOUT)) != 0
        }
        // A signal is not the peer's fault; anything else is give-up.
        return ready < 0 && errno == EINTR
    }

    // MARK: - Helpers

    private static func headerValue(_ name: String, in header: String) -> String? {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces)
                    .caseInsensitiveCompare(name) == .orderedSame
            else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func acceptKey(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + wsGUID).utf8))
        return Data(digest).base64EncodedString()
    }
}
