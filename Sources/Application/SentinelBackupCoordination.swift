// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum SentinelAIDataExport {
    static let requestName = Notification.Name("com.phibrowser.sentinel.exportAIData.request")
    static let responseName = Notification.Name("com.phibrowser.sentinel.exportAIData.response")

    struct Response: Equatable {
        enum Status: String {
            case completed
            case error
        }

        let status: Status
        let path: String?
        let error: String?
    }

    static func requestUserInfo(
        requestID: String,
        destinationPath: String
    ) -> [String: String] {
        [
            "requestID": requestID,
            "destinationPath": destinationPath
        ]
    }

    static func parseResponse(_ info: [String: String]) -> Response? {
        guard let rawStatus = info["status"],
              let status = Response.Status(rawValue: rawStatus) else {
            return nil
        }
        return Response(
            status: status,
            path: info["path"],
            error: info["error"]
        )
    }
}

protocol SentinelNotificationSubscription: AnyObject {
    func cancel()
}

protocol SentinelNotificationTransport {
    func post(
        name: Notification.Name,
        object: String,
        userInfo: [String: String]
    )

    func observe(
        name: Notification.Name,
        object: String,
        handler: @escaping ([String: String]) -> Void
    ) -> SentinelNotificationSubscription
}

final class DistributedSentinelNotificationTransport: SentinelNotificationTransport {
    private final class Subscription: SentinelNotificationSubscription {
        private let token: NSObjectProtocol

        init(token: NSObjectProtocol) {
            self.token = token
        }

        func cancel() {
            DistributedNotificationCenter.default().removeObserver(token)
        }
    }

    func post(
        name: Notification.Name,
        object: String,
        userInfo: [String: String]
    ) {
        DistributedNotificationCenter.default().postNotificationName(
            name,
            object: object,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    func observe(
        name: Notification.Name,
        object: String,
        handler: @escaping ([String: String]) -> Void
    ) -> SentinelNotificationSubscription {
        let token = DistributedNotificationCenter.default().addObserver(
            forName: name,
            object: object,
            queue: nil
        ) { notification in
            var info: [String: String] = [:]
            for (key, value) in notification.userInfo ?? [:] {
                if let key = key as? String, let value = value as? String {
                    info[key] = value
                }
            }
            handler(info)
        }
        return Subscription(token: token)
    }
}

enum SentinelCoordinationResult<Response> {
    case response(Response)
    case timedOut
    case cancelled
}

final class SentinelBackupCoordinationClient {
    private let transport: SentinelNotificationTransport
    private let sentinelBundleID: String
    private let browserBundleID: String
    private let retryDelays: [TimeInterval]

    init(
        transport: SentinelNotificationTransport = DistributedSentinelNotificationTransport(),
        sentinelBundleID: String = SentinelHelper.loginItemIdentifier(),
        browserBundleID: String = Bundle.main.bundleIdentifier ?? "",
        retryDelays: [TimeInterval] = [0, 0.5, 1, 2, 4, 8]
    ) {
        self.transport = transport
        self.sentinelBundleID = sentinelBundleID
        self.browserBundleID = browserBundleID
        self.retryDelays = retryDelays
    }

    func requestExportAIData(
        requestID: String,
        destinationPath: String,
        timeout: TimeInterval = 10 * 60
    ) async -> SentinelCoordinationResult<SentinelAIDataExport.Response> {
        let state = SendState<SentinelAIDataExport.Response>()
        let payload = SentinelAIDataExport.requestUserInfo(
            requestID: requestID,
            destinationPath: destinationPath
        ).merging(["browserBundleID": browserBundleID]) { current, _ in current }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let subscription = transport.observe(
                    name: SentinelAIDataExport.responseName,
                    object: sentinelBundleID
                ) { info in
                    guard info["requestID"] == requestID,
                          let response = SentinelAIDataExport.parseResponse(info) else {
                        return
                    }
                    state.resolve(.response(response))
                }
                state.install(
                    continuation: continuation,
                    subscription: subscription
                )

                for delay in retryDelays {
                    let retryTask = Task {
                        if delay > 0 {
                            try? await Task.sleep(
                                nanoseconds: UInt64(delay * 1_000_000_000)
                            )
                        }
                        state.performIfPending {
                            transport.post(
                                name: SentinelAIDataExport.requestName,
                                object: sentinelBundleID,
                                userInfo: payload
                            )
                        }
                    }
                    state.add(task: retryTask)
                }

                let timeoutTask = Task {
                    try? await Task.sleep(
                        nanoseconds: UInt64(max(0, timeout) * 1_000_000_000)
                    )
                    state.resolve(.timedOut)
                }
                state.add(task: timeoutTask)
            }
        } onCancel: {
            state.resolve(.cancelled)
        }
    }
}

struct SentinelAIDataExportSession {
    static let archiveFileName = "ai-data.tar.gz"
    private static let sessionLifetime: TimeInterval = 24 * 60 * 60

    let requestID: UUID
    let directoryURL: URL
    let archiveURL: URL

    static func prepare(
        sharedContainerURL: URL,
        sentinelBundleID: String,
        requestID: UUID,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> SentinelAIDataExportSession {
        let scopeURL = sharedContainerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("SentinelExports", isDirectory: true)
            .appendingPathComponent(sentinelBundleID, isDirectory: true)

        try fileManager.createDirectory(
            at: scopeURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        removeExpiredSessions(
            in: scopeURL,
            olderThan: now.addingTimeInterval(-sessionLifetime),
            fileManager: fileManager
        )

        let directoryURL = scopeURL.appendingPathComponent(
            requestID.uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return SentinelAIDataExportSession(
            requestID: requestID,
            directoryURL: directoryURL,
            archiveURL: directoryURL.appendingPathComponent(
                archiveFileName,
                isDirectory: false
            )
        )
    }

    func cleanup(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directoryURL)
    }

    func scheduleCleanup(after delay: TimeInterval = 15 * 60) {
        let directoryURL = directoryURL
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + max(0, delay)
        ) {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    private static func removeExpiredSessions(
        in scopeURL: URL,
        olderThan expirationDate: Date,
        fileManager: FileManager
    ) {
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isDirectoryKey,
            .isSymbolicLinkKey
        ]
        guard let children = try? fileManager.contentsOfDirectory(
            at: scopeURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for child in children {
            guard let values = try? child.resourceValues(forKeys: resourceKeys),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < expirationDate else {
                continue
            }
            try? fileManager.removeItem(at: child)
        }
    }
}

@MainActor
struct SentinelAIDataExportService {
    func prepareSession() throws -> SentinelAIDataExportSession {
        guard let sharedContainerURL = FileSystemUtils.sharedContainerURL() else {
            throw NSError(
                domain: "PhiUserDataBackup",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey: "The shared App Group container is unavailable."
                ]
            )
        }
        return try SentinelAIDataExportSession.prepare(
            sharedContainerURL: sharedContainerURL,
            sentinelBundleID: SentinelHelper.loginItemIdentifier(),
            requestID: UUID()
        )
    }

    func coordinate(
        session: SentinelAIDataExportSession,
        isCancelled: @escaping () -> Bool
    ) async -> AIDataExportCoordinator.Result {
        let coordinator = AIDataExportCoordinator(
            ensureSentinelRunning: {
                if SentinelHelper.isRunning {
                    return true
                }
                SentinelHelper.launch()
                for _ in 0..<32 {
                    if SentinelHelper.isRunning {
                        return true
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                return SentinelHelper.isRunning
            },
            requestExport: { requestID, destinationPath in
                await SentinelBackupCoordinationClient().requestExportAIData(
                    requestID: requestID,
                    destinationPath: destinationPath
                )
            },
            isRegularFile: { url in
                guard let attributes = try? FileManager.default.attributesOfItem(
                    atPath: url.path
                ) else {
                    return false
                }
                return attributes[.type] as? FileAttributeType == .typeRegular
            },
            isCancelled: isCancelled
        )
        return await coordinator.coordinate(
            requestID: session.requestID.uuidString,
            destinationTarURL: session.archiveURL
        )
    }
}

final class SentinelExportCancellation {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

struct AIDataExportCoordinator {
    enum Result: Equatable {
        case packed(tarURL: URL)
        case skipped(reason: SkipReason)
    }

    enum SkipReason: Equatable {
        case sentinelUnavailable
        case timedOut
        case exportFailed
        case invalidResponsePath
        case cancelled

        var shouldRetainSessionForLateWrite: Bool {
            switch self {
            case .sentinelUnavailable, .exportFailed:
                return false
            case .timedOut, .invalidResponsePath, .cancelled:
                return true
            }
        }
    }

    let ensureSentinelRunning: () async -> Bool
    let requestExport: (
        _ requestID: String,
        _ destinationPath: String
    ) async -> SentinelCoordinationResult<SentinelAIDataExport.Response>
    let isRegularFile: (URL) -> Bool
    let isCancelled: () -> Bool

    func coordinate(
        requestID: String,
        destinationTarURL: URL
    ) async -> Result {
        if isCancelled() {
            return .skipped(reason: .cancelled)
        }
        guard await ensureSentinelRunning() else {
            return .skipped(reason: .sentinelUnavailable)
        }
        if isCancelled() {
            return .skipped(reason: .cancelled)
        }

        switch await requestExport(requestID, destinationTarURL.path) {
        case .timedOut:
            return .skipped(reason: .timedOut)
        case .cancelled:
            return .skipped(reason: .cancelled)
        case .response(let response):
            guard !isCancelled() else {
                return .skipped(reason: .cancelled)
            }
            switch response.status {
            case .error:
                return .skipped(reason: .exportFailed)
            case .completed:
                guard let responsePath = response.path else {
                    return .skipped(reason: .exportFailed)
                }
                guard responsePath == destinationTarURL.path else {
                    return .skipped(reason: .invalidResponsePath)
                }
                guard isRegularFile(destinationTarURL) else {
                    return .skipped(reason: .exportFailed)
                }
                return .packed(tarURL: destinationTarURL)
            }
        }
    }
}

private final class SendState<Response> {
    typealias Result = SentinelCoordinationResult<Response>
    typealias Continuation = CheckedContinuation<Result, Never>

    private let lock = NSLock()
    private var resolvedResult: Result?
    private var continuation: Continuation?
    private var subscription: SentinelNotificationSubscription?
    private var tasks: [Task<Void, Never>] = []

    func install(
        continuation: Continuation,
        subscription: SentinelNotificationSubscription
    ) {
        lock.lock()
        if let resolvedResult {
            lock.unlock()
            subscription.cancel()
            continuation.resume(returning: resolvedResult)
            return
        }
        self.continuation = continuation
        self.subscription = subscription
        lock.unlock()
    }

    func add(task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = resolvedResult != nil
        if !shouldCancel {
            tasks.append(task)
        }
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func performIfPending(_ body: () -> Void) {
        lock.lock()
        let shouldPerform = resolvedResult == nil
        lock.unlock()
        if shouldPerform {
            body()
        }
    }

    func resolve(_ result: Result) {
        lock.lock()
        guard resolvedResult == nil else {
            lock.unlock()
            return
        }
        resolvedResult = result
        let continuation = continuation
        self.continuation = nil
        let subscription = subscription
        self.subscription = nil
        let tasks = tasks
        self.tasks = []
        lock.unlock()

        subscription?.cancel()
        for task in tasks {
            task.cancel()
        }
        continuation?.resume(returning: result)
    }
}
