// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
import Darwin
import Foundation

/// Direct Swift-side transport for `agentSpace.*` calls.
///
/// The management and lifecycle surface (Spaces, profiles, URL rules,
/// bookmarks, pinned tabs, ownership, ping, …) is owned entirely by the Mac
/// client — Chromium holds none of that state. Historically the skill still
/// reached it by tunnelling every message through Chromium's DevTools server
/// (the `PhiAgentSpace.sendMessage` CDP command), a needless hop out to
/// Chromium and back. Now that the app owns the CDP socket, an agent that
/// upgrades to `GET /phi-agent` is served here instead: frames are routed
/// straight into `ExtensionMessageRouter` (as sender "cdp", same as the
/// tunnel), and `agentSpace.*` broadcasts are pushed back over the same
/// socket. Page automation (stock CDP) still goes to Chromium untouched; the
/// framework keeps the legacy tunnel command only for older tooling that
/// still routes `agentSpace.*` through the DevTools server.
///
/// Wire protocol (JSON text frames):
///   request  → {"id": N, "type": "agentSpace.…", "payloadJson": "…"}
///   response ← {"id": N, "responseJson": "…"}  or  {"id": N, "error": "…"}
///   event    ← {"event": "agentSpace.…", "payloadJson": "…"}

/// One app-issued logical driver session. `capability` is a bearer secret
/// returned on the first `/phi-agent` upgrade and presented by sandboxed or
/// detached helpers on later connections. It keeps process churn from
/// collapsing authorization back to a caller-supplied pid or display name.
struct AgentDriverSession {
    let principalId: String
    let capability: String
    let identity: AgentIdentity
    /// The owning process's session anchor at issuance (see
    /// `AgentPeerIdentity.processSessionAnchor`), nil when the identity had
    /// no resolvable process. Re-resolving it answers "is the owner still
    /// that same process launch?" for adoption and pruning.
    let processAnchor: String?
    /// Issuance time — the prune sweep's grace reference, so a session can't
    /// be dropped between being minted on the auth queue and its connection
    /// or task becoming visible.
    let createdAt: Date
}

/// App-session registry for logical driver principals. A live agent process
/// gets one principal across its short-lived helper connections; a detached
/// helper must prove delegation by presenting the issued capability.
final class AgentDriverSessionRegistry {
    static let shared = AgentDriverSessionRegistry()

    private let lock = NSLock()
    private var sessionsByCapability: [String: AgentDriverSession] = [:]
    private var capabilityByProcessAnchor: [String: String] = [:]
    private var sweepTimer: DispatchSourceTimer?

    private static let sweepInterval: TimeInterval = 60
    /// A session younger than this is never pruned, covering the gap between
    /// issuance on the auth queue and its connection/task becoming visible to
    /// the sweep's retention query.
    static let pruneGraceSeconds: TimeInterval = 120

    private init() {}

    func session(forCapability capability: String) -> AgentDriverSession? {
        lock.lock(); defer { lock.unlock() }
        return sessionsByCapability[capability]
    }

    func session(for identity: AgentIdentity) -> AgentDriverSession {
        lock.lock(); defer { lock.unlock() }
        ensureSweepScheduledLocked()
        let anchor = AgentPeerIdentity.processSessionAnchor(for: identity)
        if let anchor,
           let capability = capabilityByProcessAnchor[anchor],
           let existing = sessionsByCapability[capability] {
            return existing
        }

        let session = AgentDriverSession(
            principalId: UUID().uuidString,
            capability: Self.makeCapability(),
            identity: identity,
            processAnchor: anchor,
            createdAt: Date())
        sessionsByCapability[session.capability] = session
        if let anchor {
            capabilityByProcessAnchor[anchor] = session.capability
        }
        return session
    }

    /// Bounds capability lifetime and registry growth: drops every session
    /// whose owning process launch is gone — invalidating its capability —
    /// EXCEPT principals named in `retaining` (live task owners and live
    /// connections), so a mirror daemon can finish its deferred completion
    /// after its agent exits and a dead owner's task stays adoptable until
    /// the task itself ends. `now` is injectable for tests.
    func prune(retaining retainedPrincipals: Set<String>, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        for (capability, session) in sessionsByCapability {
            guard now.timeIntervalSince(session.createdAt) > Self.pruneGraceSeconds,
                  !retainedPrincipals.contains(session.principalId),
                  !Self.ownerProcessAlive(session) else { continue }
            sessionsByCapability[capability] = nil
            if let anchor = session.processAnchor,
               capabilityByProcessAnchor[anchor] == capability {
                capabilityByProcessAnchor[anchor] = nil
            }
        }
    }

    /// Lazy periodic sweep, armed once the first session exists. Retention
    /// state lives on the main thread (task records) and behind the channel
    /// registry's own lock, so the gather hops to main before pruning.
    private func ensureSweepScheduledLocked() {
        guard sweepTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.sweepInterval,
                       repeating: Self.sweepInterval)
        timer.setEventHandler {
            DispatchQueue.main.async {
                let retained = AgentSpaceManager.shared.liveDriverPrincipalIds
                    .union(AgentDirectChannelRegistry.shared.livePrincipalIds)
                AgentDriverSessionRegistry.shared.prune(retaining: retained)
            }
        }
        timer.resume()
        sweepTimer = timer
    }

    /// The restart-recovery rule: `callerPrincipalId` may adopt a task owned
    /// by `taskPrincipalId` only when the owning session's process is GONE
    /// (its anchor no longer resolves to the same launch) and the caller is
    /// the same consent identity that owned it. Never true while the owner
    /// still runs — a live task stays isolated to its own principal — and
    /// never true for the unresolvable "unknown" identity, which would make
    /// every unidentified peer interchangeable.
    func canAdopt(taskPrincipalId: String, callerPrincipalId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard taskPrincipalId != callerPrincipalId,
              let owner = sessionsByCapability.values
                .first(where: { $0.principalId == taskPrincipalId }),
              let caller = sessionsByCapability.values
                .first(where: { $0.principalId == callerPrincipalId }),
              owner.identity.key == caller.identity.key,
              !owner.identity.isUnresolved else {
            return false
        }
        return !Self.ownerProcessAlive(owner)
    }

    /// True while the session's owning process is still the launch the
    /// session was issued to. A nil anchor (identity with no resolvable
    /// process) can never be revalidated and counts as gone.
    private static func ownerProcessAlive(_ session: AgentDriverSession) -> Bool {
        guard let anchor = session.processAnchor else { return false }
        return AgentPeerIdentity.processSessionAnchor(for: session.identity) == anchor
    }

    private static func makeCapability() -> String {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Tracks live `/phi-agent` connections and routes app responses/broadcasts to
/// them. `ExtensionMessaging` consults this before falling back to the Chromium
/// bridge, so a response for a direct-channel request never leaves the app.
/// Thread-safe; methods are called from both connection queues and the main
/// thread.
final class AgentDirectChannelRegistry {
    static let shared = AgentDirectChannelRegistry()

    private struct Pending {
        let connectionId: String
        let clientId: Int
        let timeout: DispatchWorkItem
    }

    private let lock = NSLock()
    private var connections: [String: AgentDirectConnection] = [:]
    private var pending: [String: Pending] = [:]

    private init() {}

    var hasConnections: Bool {
        lock.lock(); defer { lock.unlock() }
        return !connections.isEmpty
    }

    /// Principals with at least one live `/phi-agent` connection — retained
    /// by the driver-session registry's prune sweep.
    var livePrincipalIds: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(connections.values.map(\.driverPrincipalId))
    }

    func add(_ connection: AgentDirectConnection) {
        lock.lock(); connections[connection.id] = connection; lock.unlock()
    }

    func remove(_ connection: AgentDirectConnection) {
        lock.lock()
        connections[connection.id] = nil
        for (requestId, p) in pending where p.connectionId == connection.id {
            p.timeout.cancel()
            pending[requestId] = nil
        }
        lock.unlock()
    }

    func closeAll() {
        lock.lock()
        let conns = Array(connections.values)
        lock.unlock()
        for c in conns { c.close() }
    }

    /// Registers a request awaiting an async app reply, arming a timeout that
    /// fails it if the handler never responds.
    func registerPending(requestId: String, connectionId: String, clientId: Int,
                         timeoutSeconds: TimeInterval = 60) {
        let timeout = DispatchWorkItem { [weak self] in
            _ = self?.deliverError(requestId: requestId, error: "timed out")
        }
        lock.lock()
        pending[requestId] = Pending(connectionId: connectionId, clientId: clientId,
                                     timeout: timeout)
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
    }

    /// Delivers an app response to the originating direct connection. Returns
    /// false when `requestId` isn't ours, so `ExtensionMessaging` falls through
    /// to the Chromium bridge.
    @discardableResult
    func deliverResponse(requestId: String, response: String) -> Bool {
        deliver(requestId: requestId) { conn, clientId in
            conn.sendResult(clientId: clientId, responseJson: response)
        }
    }

    @discardableResult
    func deliverError(requestId: String, error: String) -> Bool {
        deliver(requestId: requestId) { conn, clientId in
            conn.sendError(clientId: clientId, error: error)
        }
    }

    private func deliver(requestId: String,
                         write: (AgentDirectConnection, Int) -> Void) -> Bool {
        lock.lock()
        guard let p = pending.removeValue(forKey: requestId) else {
            lock.unlock(); return false
        }
        p.timeout.cancel()
        let conn = connections[p.connectionId]
        lock.unlock()
        guard let conn else { return true }  // ours, but the client vanished
        write(conn, p.clientId)
        return true
    }

    /// Pushes a task event only to connections authorized as its owning
    /// logical driver. Several round/helper connections may share a principal.
    func broadcast(type: String, payloadJson: String, principalId: String) {
        lock.lock()
        let conns = connections.values.filter { $0.driverPrincipalId == principalId }
        lock.unlock()
        for c in conns { c.sendEvent(type: type, payloadJson: payloadJson) }
    }

    /// App-global, non-task event fan-out retained for existing extension-style
    /// broadcasts. Task/user-content events must use the principal overload.
    func broadcast(type: String, payloadJson: String) {
        lock.lock(); let conns = Array(connections.values); lock.unlock()
        for c in conns { c.sendEvent(type: type, payloadJson: payloadJson) }
    }
}

/// One `/phi-agent` WebSocket connection: a minimal server-side RFC 6455
/// endpoint (the mirror of the skill's client codec) that decodes agent
/// requests and encodes responses/events. Owns its fd for its whole lifetime.
final class AgentDirectConnection {
    let id = UUID().uuidString
    let driverPrincipalId: String

    private let fd: Int32
    /// The authenticated identity of the connecting code agent, forwarded to
    /// `agentSpace.create` so the Space it opens is badged with who drives it.
    private let agentName: String
    /// Bearer capability for this logical driver session. Echoed on the 101
    /// response so the skill can delegate it to its sandboxed/detached helpers.
    private let agentCapability: String
    /// Pid of the resolved agent process, echoed back on the 101 upgrade
    /// (X-Phi-Agent-Pid) — the authoritative ancestry answer for a skill
    /// round that cannot walk its own (Codex's seatbelt denies the sysctls
    /// `ps` needs). The skill records it for its detached daemon and
    /// watchers to claim on later connections.
    private let agentPid: pid_t?
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var handshakeDone = false
    private var closed = false
    private var fragOpcode: UInt8 = 0
    private var fragData = Data()

    private static let wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    private static let maxFrameBytes = 8 * 1024 * 1024

    /// How long one write may wait for a client that has stopped reading.
    /// Generous, because the alternative is dropping a reply the caller is
    /// still waiting on, and bounded, because a wedged client must not pin
    /// this connection's queue forever.
    private static let writeStallTimeoutMs = 15_000

    init(fd: Int32, agentName: String = "", agentPid: pid_t? = nil,
         driverPrincipalId: String, agentCapability: String) {
        self.fd = fd
        self.agentName = agentName
        self.agentPid = agentPid
        self.driverPrincipalId = driverPrincipalId
        self.agentCapability = agentCapability
        self.queue = DispatchQueue(label: "com.phibrowser.cdp.direct.\(fd)")
    }

    func start() {
        AgentDirectChannelRegistry.shared.add(self)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.onReadable() }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            Darwin.close(self.fd)
        }
        readSource = source
        source.resume()
    }

    func close() {
        queue.async { [weak self] in self?.teardown() }
    }

    private func teardown() {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        readSource = nil
        AgentDirectChannelRegistry.shared.remove(self)
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
            if n == 0 { teardown(); return }        // peer closed
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            if errno == EINTR { continue }
            teardown(); return
        }
        if !handshakeDone {
            guard processHandshake() else { return }
        }
        drainFrames()
    }

    /// Completes the WebSocket upgrade once the request headers have arrived.
    private func processHandshake() -> Bool {
        guard let headerEnd = range(of: "\r\n\r\n") else { return false }
        let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        buffer.removeSubrange(..<headerEnd.upperBound)

        guard let key = Self.headerValue("Sec-WebSocket-Key", in: header) else {
            writeRaw("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
            teardown()
            return false
        }
        let accept = Self.acceptKey(for: key)
        let claim = agentPid.map { "X-Phi-Agent-Pid: \($0)\r\n" } ?? ""
        let capability = "X-Phi-Agent-Capability: \(agentCapability)\r\n"
        writeRaw(
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
            claim +
            capability +
            "Sec-WebSocket-Accept: \(accept)\r\n\r\n")
        handshakeDone = true
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
                var v = 0
                for i in 0..<8 { v = (v << 8) | Int(buffer[buffer.startIndex + 2 + i]) }
                len = v
                offset = 10
            }
            if len > Self.maxFrameBytes { teardown(); return }
            // Client frames MUST be masked (RFC 6455 §5.1).
            guard masked else { teardown(); return }
            guard buffer.count >= offset + 4 + len else { return }
            let maskStart = buffer.startIndex + offset
            let mask = Array(buffer[maskStart..<maskStart + 4])
            let payloadStart = maskStart + 4
            var payload = [UInt8](repeating: 0, count: len)
            for i in 0..<len {
                payload[i] = buffer[payloadStart + i] ^ mask[i & 3]
            }
            buffer.removeSubrange(buffer.startIndex..<(payloadStart + len))
            handleFrame(fin: fin, opcode: opcode, payload: payload)
        }
    }

    private func handleFrame(fin: Bool, opcode: UInt8, payload: [UInt8]) {
        switch opcode {
        case 0x8:                                   // close
            writeFrame(opcode: 0x8, payload: payload)
            teardown()
        case 0x9:                                   // ping -> pong
            writeFrame(opcode: 0xa, payload: payload)
        case 0xa:                                   // pong
            break
        case 0x0:                                   // continuation
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
        guard opcode == 0x1 else { return }         // JSON is text only
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientId = obj["id"] as? Int,
              let type = obj["type"] as? String else { return }
        let payloadJson = obj["payloadJson"] as? String ?? "{}"
        DispatchQueue.main.async { [weak self] in
            self?.route(clientId: clientId, type: type, payloadJson: payloadJson)
        }
    }

    /// Main-thread: run the request through the same router the CDP tunnel uses,
    /// then reply synchronously or await the async app response.
    private func route(clientId: Int, type: String, payloadJson: String) {
        let requestId = "agentdirect:\(id):\(clientId)"
        // Credential requests can legitimately sit behind the 60s approval
        // prompt AND a 60s in-flow unlock prompt; don't let the transport kill
        // them under the user's nose. Everything else keeps the tight timeout.
        let timeout: TimeInterval = type.hasPrefix("credentials.") ? 180 : 60
        AgentDirectChannelRegistry.shared.registerPending(
            requestId: requestId, connectionId: id, clientId: clientId,
            timeoutSeconds: timeout)
        let sync = ExtensionMessageRouter.shared.handle(
            type: type, payload: payloadJson, requestId: requestId, senderId: "cdp",
            agentName: agentName, driverPrincipalId: driverPrincipalId)
        if let sync {
            AgentDirectChannelRegistry.shared.deliverResponse(
                requestId: requestId, response: sync)
        }
        // Otherwise the handler replies later via ExtensionMessaging, which
        // routes back through the registry (or the timeout fires).
    }

    // MARK: - Writing (any thread; serialized on `queue`)

    func sendResult(clientId: Int, responseJson: String) {
        let obj: [String: Any] = ["id": clientId, "responseJson": responseJson]
        sendJSON(obj)
    }

    func sendError(clientId: Int, error: String) {
        let obj: [String: Any] = ["id": clientId, "error": error]
        sendJSON(obj)
    }

    func sendEvent(type: String, payloadJson: String) {
        let obj: [String: Any] = ["event": type, "payloadJson": payloadJson]
        sendJSON(obj)
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        queue.async { [weak self] in
            self?.writeFrame(opcode: 0x1, payload: [UInt8](data))
        }
    }

    /// Server frames are never masked (RFC 6455 §5.1).
    private func writeFrame(opcode: UInt8, payload: [UInt8]) {
        guard !closed else { return }
        var frame = [UInt8]()
        frame.append(0x80 | opcode)
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(len))
        } else if len < 65536 {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xff))
            frame.append(UInt8(len & 0xff))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len >> shift) & 0xff))
            }
        }
        frame.append(contentsOf: payload)
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
        // so the client would misread this frame and every one after it. A
        // closed connection is recoverable; a desynchronised one is not.
        teardown()
    }

    /// Waits for the socket to accept more bytes.
    ///
    /// The fd is non-blocking, so any response larger than the send buffer
    /// hits EAGAIN partway through a frame — a big page snapshot or an
    /// extracted article will do it. This runs on the connection's own serial
    /// queue, so the wait delays only this connection's later writes and never
    /// the app. False means the peer stopped reading for longer than a stalled
    /// client is worth, or the socket failed.
    private func waitWritable() -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&descriptor, 1, Int32(Self.writeStallTimeoutMs))
        if ready > 0 {
            return (descriptor.revents & Int16(POLLOUT)) != 0
        }
        // A signal is not the peer's fault; anything else is give-up.
        return ready < 0 && errno == EINTR
    }

    // MARK: - Buffer helpers

    private func range(of marker: String) -> Range<Data.Index>? {
        buffer.range(of: Data(marker.utf8))
    }

    private static func headerValue(_ name: String, in header: String) -> String? {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame
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
