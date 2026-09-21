import Foundation

/// Routing metadata only. The existing sync engines remain responsible for fetching data.
struct PhiSyncInvalidation: Codable, Equatable, Sendable {
    let namespace: String
    var dataTypes: [Int]
    var sourceClientID: String

    enum CodingKeys: String, CodingKey {
        case namespace
        case dataTypes = "data_types"
        case sourceClientID = "source_client_id"
    }

    var profileUUID: String? {
        guard namespace.hasPrefix("chromium:"), namespace != "chromium:phi" else { return nil }
        return String(namespace.dropFirst("chromium:".count))
    }

    var isValid: Bool {
        let suffix = namespace.dropFirst("chromium:".count)
        return namespace.hasPrefix("chromium:") && !suffix.isEmpty && suffix.utf8.count <= 64
            && suffix.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || [45, 46, 95].contains($0) }
            && !dataTypes.isEmpty && dataTypes.count <= 64
            && dataTypes.allSatisfy { $0 > 0 && $0 <= Int(Int32.max) }
            && sourceClientID.utf8.count <= 256
    }
}

enum PhiSyncInvalidationError: Error {
    case malformedEvent, oversizedEvent, invalidResponse, missingToken, invalidURL
    case http(Int)
}

enum PhiSyncInvalidationEvent: Equatable, Sendable {
    case ready
    case invalidate(PhiSyncInvalidation)
    case heartbeat
}

/// Incremental, bounded SSE parser. Incomplete final events are discarded on reconnect.
struct PhiSyncInvalidationParser {
    static let maximumEventBytes = 16 * 1024
    private var line = Data()
    private var eventName = ""
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var previousWasCR = false
    private var firstLine = true

    mutating func feed(_ bytes: Data) throws -> [PhiSyncInvalidationEvent] {
        var events: [PhiSyncInvalidationEvent] = []
        for byte in bytes {
            if previousWasCR {
                previousWasCR = false
                if byte == 10 { continue }
            }
            if byte == 10 || byte == 13 {
                if let event = try finishLine() { events.append(event) }
                previousWasCR = byte == 13
            } else {
                guard line.count < Self.maximumEventBytes else { throw PhiSyncInvalidationError.oversizedEvent }
                line.append(byte)
            }
        }
        return events
    }

    private mutating func finishLine() throws -> PhiSyncInvalidationEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        if firstLine {
            firstLine = false
            if line.starts(with: [0xef, 0xbb, 0xbf]) { line.removeFirst(3) }
        }
        guard let text = String(data: line, encoding: .utf8) else {
            throw PhiSyncInvalidationError.malformedEvent
        }
        if text.isEmpty {
            defer { eventName = ""; dataLines.removeAll(keepingCapacity: true); eventBytes = 0 }
            guard !dataLines.isEmpty else { return nil }
            let payload = Data(dataLines.joined(separator: "\n").utf8)
            switch eventName {
            case "ready":
                guard (try? JSONSerialization.jsonObject(with: payload)) is [String: Any] else {
                    throw PhiSyncInvalidationError.malformedEvent
                }
                return .ready
            case "invalidate":
                guard let hint = try? JSONDecoder().decode(PhiSyncInvalidation.self, from: payload), hint.isValid else {
                    throw PhiSyncInvalidationError.malformedEvent
                }
                return .invalidate(hint)
            default: return nil
            }
        }
        if text.hasPrefix(":") { return .heartbeat }
        eventBytes += line.count
        guard eventBytes <= Self.maximumEventBytes else { throw PhiSyncInvalidationError.oversizedEvent }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch parts[0] {
        case "event": eventName = value
        case "data": dataLines.append(value)
        default: break // SSE id/retry fields are not a durable sync cursor.
        }
        return nil
    }
}

enum PhiSyncInvalidationDemand: Equatable, Sendable {
    case catchUp
    case changes([PhiSyncInvalidation])
}

/// Owns only scheduling and connection health, never sync state or account/key material.
/// Closures make it executable in hostless tests without launching Chromium or reading defaults.
@MainActor
final class PhiSyncInvalidationCoordinator {
    typealias Stream = @Sendable (@escaping @Sendable (Data) async throws -> Void) async throws -> Void
    typealias Pull = @MainActor @Sendable (PhiSyncInvalidationDemand) async -> Void

    struct Configuration {
        var fallbackInterval: TimeInterval = 60
        var healthyInterval: TimeInterval = 300
        var watchdogInterval: TimeInterval = 45
        var tickInterval: TimeInterval = 5
        var coalescingInterval: TimeInterval = 0.25
        var retryDelay: @Sendable (Int) -> TimeInterval = { failures in
            min(60, pow(2, Double(min(failures, 6)))) * Double.random(in: 0.8...1.0)
        }
    }

    private let stream: Stream
    private let pull: Pull
    private let now: () -> TimeInterval
    private let configuration: Configuration
    private var streamTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var coalescingTask: Task<Void, Never>?
    private var pullTask: Task<Void, Never>?
    private var generation = UUID()
    private var attempt: UUID?
    private var parser = PhiSyncInvalidationParser()
    private var lastActivity: TimeInterval = 0
    private var attemptStarted: TimeInterval = 0
    private var nextPoll: TimeInterval = 0
    private var pendingCatchUp = false
    private var pendingHints: [String: PhiSyncInvalidation] = [:]
    private(set) var isRunning = false
    private(set) var isHealthy = false

    init(configuration: Configuration = Configuration(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         stream: @escaping Stream,
         pull: @escaping Pull) {
        self.configuration = configuration
        self.now = now
        self.stream = stream
        self.pull = pull
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        nextPoll = now() + configuration.fallbackInterval
        reconnect()
        requestCatchUp()
        let interval = configuration.tickInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Self.sleep(interval) } catch { return }
                self?.tick()
            }
        }
    }

    func stop() {
        isRunning = false
        generation = UUID()
        attempt = nil
        streamTask?.cancel(); streamTask = nil
        tickTask?.cancel(); tickTask = nil
        coalescingTask?.cancel(); coalescingTask = nil
        pullTask?.cancel(); pullTask = nil
        pendingCatchUp = false
        pendingHints.removeAll()
        isHealthy = false
    }

    /// Tokens are re-read by the backend transport for each attempt.
    func reconnect() {
        guard isRunning else { return }
        streamTask?.cancel()
        attempt = nil
        setHealthy(false)
        let stream = self.stream
        let epoch = generation
        let retryDelay = configuration.retryDelay
        streamTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let token = self?.beginAttempt(generation: epoch) else { return }
                do {
                    try await stream { [weak self] data in
                        try Task.checkCancellation()
                        try await self?.receive(data, attempt: token)
                    }
                } catch { /* Only connection state is retained; never log payloads or tokens. */ }
                guard !Task.isCancelled else { return }
                guard let wasHealthy = self?.endAttempt(token) else { return }
                failures = wasHealthy ? 0 : min(failures + 1, 6)
                do { try await Self.sleep(retryDelay(failures)) } catch { return }
            }
        }
    }

    func foregroundOrWake() {
        guard isRunning else { return }
        requestCatchUp()
        reconnect()
    }

    func requestCatchUp() {
        guard isRunning else { return }
        pendingCatchUp = true
        pendingHints.removeAll()
        schedulePull()
    }

    /// Called by the production timer; injected monotonic time makes deadlines testable.
    func tick() {
        guard isRunning else { return }
        if now() >= nextPoll {
            nextPoll = now() + (isHealthy ? configuration.healthyInterval : configuration.fallbackInterval)
            requestCatchUp()
        }
        if attempt != nil,
           now() - (isHealthy ? lastActivity : attemptStarted) >= configuration.watchdogInterval {
            reconnect()
        }
    }

    private func beginAttempt(generation epoch: UUID) -> UUID? {
        guard isRunning, generation == epoch, !Task.isCancelled else { return nil }
        let token = UUID()
        attempt = token
        parser = PhiSyncInvalidationParser()
        lastActivity = now()
        attemptStarted = lastActivity
        return token
    }

    private func receive(_ data: Data, attempt token: UUID) throws {
        guard isRunning, attempt == token else { throw CancellationError() }
        lastActivity = now()
        for event in try parser.feed(data) {
            switch event {
            case .ready:
                setHealthy(true)
                requestCatchUp()
            case .heartbeat: break
            case .invalidate(let hint):
                guard isHealthy else { throw PhiSyncInvalidationError.malformedEvent }
                guard !pendingCatchUp else { continue }
                if var old = pendingHints[hint.namespace] {
                    old.dataTypes = Array(Set(old.dataTypes + hint.dataTypes)).sorted()
                    if old.dataTypes.count > 64 {
                        pendingCatchUp = true
                        pendingHints.removeAll()
                    } else {
                        if old.sourceClientID != hint.sourceClientID { old.sourceClientID = "" }
                        pendingHints[hint.namespace] = old
                    }
                } else if pendingHints.count < 128 {
                    pendingHints[hint.namespace] = hint
                } else {
                    // Bounded memory during a stalled engine: a catch-up covers all hints.
                    pendingCatchUp = true
                    pendingHints.removeAll()
                }
                schedulePull()
            }
        }
    }

    private func endAttempt(_ token: UUID) -> Bool? {
        guard attempt == token, isRunning else { return nil }
        let wasHealthy = isHealthy
        attempt = nil
        setHealthy(false)
        return wasHealthy
    }

    private func setHealthy(_ value: Bool) {
        guard isHealthy != value else { return }
        isHealthy = value
        nextPoll = now() + (value ? configuration.healthyInterval : configuration.fallbackInterval)
    }

    private func schedulePull() {
        guard coalescingTask == nil, pullTask == nil else { return }
        let epoch = generation
        let delay = configuration.coalescingInterval
        coalescingTask = Task { [weak self] in
            do { try await Self.sleep(delay) } catch { return }
            guard let self, self.isRunning, self.generation == epoch else { return }
            self.coalescingTask = nil
            self.flush()
        }
    }

    private func flush() {
        guard isRunning, pullTask == nil, pendingCatchUp || !pendingHints.isEmpty else { return }
        let demand: PhiSyncInvalidationDemand = pendingCatchUp ? .catchUp
            : .changes(pendingHints.values.sorted { $0.namespace < $1.namespace })
        pendingCatchUp = false
        pendingHints.removeAll()
        let epoch = generation
        let pull = self.pull
        pullTask = Task { [weak self] in
            await pull(demand)
            guard !Task.isCancelled, let self, self.isRunning, self.generation == epoch else { return }
            self.pullTask = nil
            if self.pendingCatchUp || !self.pendingHints.isEmpty { self.schedulePull() }
        }
    }

    private nonisolated static func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 3600)) * 1_000_000_000))
    }
}

/// Per-task redirect policy also applies when using the backend's injected URLSession.
final class PhiSyncInvalidationRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Streaming operation of the existing sync backend client, separated for hostless tests.
enum PhiSyncInvalidationHTTPStream {
    static func run(session: URLSession, baseURL: String, deviceID: String,
                    tokenProvider: () async -> String?,
                    receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        guard var url = URLComponents(string: baseURL),
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")),
              url.user == nil, url.password == nil, url.host != nil else {
            throw PhiSyncInvalidationError.invalidURL
        }
        url.path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/").map(String.init).map { "/" + $0 }.joined() + "/sync/invalidations"
        url.queryItems = [URLQueryItem(name: "client_id", value: deviceID)]
        url.fragment = nil
        guard let endpoint = url.url else { throw PhiSyncInvalidationError.invalidURL }
        guard let token = await tokenProvider(), !token.isEmpty else { throw PhiSyncInvalidationError.missingToken }
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 45
        let (bytes, response) = try await session.bytes(for: request, delegate: PhiSyncInvalidationRedirectPolicy())
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PhiSyncInvalidationError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() == "text/event-stream" else {
            throw PhiSyncInvalidationError.invalidResponse
        }
        var chunk = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            chunk.append(byte)
            if byte == 10 || byte == 13 || chunk.count >= 1024 {
                try await receive(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { try await receive(chunk) }
    }
}
