// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

// MARK: - Contract value types

/// Export AI data: browser asks Sentinel to write `ai-data.tar.gz` to a path.
enum SentinelAIDataExport {
    static let requestName = Notification.Name("com.phibrowser.sentinel.exportAIData.request")
    static let responseName = Notification.Name("com.phibrowser.sentinel.exportAIData.response")

    struct Response: Equatable {
        enum Status: String { case completed, error }
        let status: Status
        let path: String?
        let error: String?
    }

    static func requestUserInfo(requestID: String, destinationPath: String) -> [String: String] {
        ["requestID": requestID, "destinationPath": destinationPath]
    }

    static func parseResponse(_ info: [String: String]) -> Response? {
        guard let raw = info["status"], let status = Response.Status(rawValue: raw) else { return nil }
        return Response(status: status, path: info["path"], error: info["error"])
    }
}

/// Import AI data: browser hands Sentinel a `ai-data.tar.gz` it already confirmed.
enum SentinelAIDataImport {
    static let requestName = Notification.Name("com.phibrowser.sentinel.importAIData.request")
    static let responseName = Notification.Name("com.phibrowser.sentinel.importAIData.response")

    struct Response: Equatable {
        enum Status: String { case completed, error }
        let status: Status
        let needsAttention: Bool
    }

    static func requestUserInfo(requestID: String, path: String, confirmed: Bool) -> [String: String] {
        // All wire scalars are strings (has_token precedent): confirmed is "true"/"false".
        ["requestID": requestID, "path": path, "confirmed": confirmed ? "true" : "false"]
    }

    static func parseResponse(_ info: [String: String]) -> Response? {
        guard let raw = info["status"], let status = Response.Status(rawValue: raw) else { return nil }
        // needsAttention arrives as the string "true"/"false"; anything other than
        // "true" (including absent) is treated as false.
        return Response(status: status, needsAttention: info["needsAttention"] == "true")
    }
}

/// Prepare for rollback: browser asks Sentinel to restore its paired snapshot.
enum SentinelPrepareForRollback {
    static let requestName = Notification.Name("com.phibrowser.sentinel.prepareForRollback.request")
    static let responseName = Notification.Name("com.phibrowser.sentinel.prepareForRollback.response")

    struct Response: Equatable {
        enum Status: String { case restored, noSnapshot, error }
        let status: Status
    }

    static func requestUserInfo(requestID: String, targetBrowserVersion: String, fromBrowserVersion: String?, operationID: String) -> [String: String] {
        // fromBrowserVersion is optional: old backup records may predate
        // creatingVersion. Omit the key entirely (never send an empty string)
        // — Sentinel falls back to the installed Phi.app version when absent.
        var userInfo = ["requestID": requestID, "targetBrowserVersion": targetBrowserVersion, "operationID": operationID]
        if let fromBrowserVersion {
            userInfo["fromBrowserVersion"] = fromBrowserVersion
        }
        return userInfo
    }

    static func parseResponse(_ info: [String: String]) -> Response? {
        guard let raw = info["status"], let status = Response.Status(rawValue: raw) else { return nil }
        return Response(status: status)
    }
}

// MARK: - Transport seam

protocol SentinelNotificationSubscription: AnyObject {
    func cancel()
}

protocol SentinelNotificationTransport {
    func post(name: Notification.Name, object: String, userInfo: [String: String])
    func observe(
        name: Notification.Name,
        object: String,
        handler: @escaping ([String: String]) -> Void
    ) -> SentinelNotificationSubscription
}

/// Real transport over `DistributedNotificationCenter`, mirroring the send
/// convention already used by `SentinelHelper` (object routing, deliverImmediately).
final class DistributedSentinelNotificationTransport: SentinelNotificationTransport {
    private final class Subscription: SentinelNotificationSubscription {
        private let token: NSObjectProtocol
        init(token: NSObjectProtocol) { self.token = token }
        func cancel() { DistributedNotificationCenter.default().removeObserver(token) }
    }

    func post(name: Notification.Name, object: String, userInfo: [String: String]) {
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
        ) { note in
            var info: [String: String] = [:]
            for (key, value) in note.userInfo ?? [:] {
                if let key = key as? String, let value = value as? String {
                    info[key] = value
                }
            }
            handler(info)
        }
        return Subscription(token: token)
    }
}

// MARK: - Client

enum SentinelCoordinationResult<Response> {
    case response(Response)
    case timedOut
}

/// Single request/response client for the three backup coordination contracts.
/// Posts on the Sentinel channel, listens for the matching `.response`,
/// dedups on `requestID`, and resolves to `.timedOut` if none arrives in time.
final class SentinelBackupCoordinationClient {
    private let transport: SentinelNotificationTransport
    private let sentinelBundleID: String
    private let browserBundleID: String

    init(
        transport: SentinelNotificationTransport = DistributedSentinelNotificationTransport(),
        sentinelBundleID: String = SentinelHelper.loginItemIdentifier(),
        browserBundleID: String = Bundle.main.bundleIdentifier ?? ""
    ) {
        self.transport = transport
        self.sentinelBundleID = sentinelBundleID
        self.browserBundleID = browserBundleID
    }

    func requestExportAIData(
        destinationPath: String,
        timeout: TimeInterval = 600
    ) async -> SentinelCoordinationResult<SentinelAIDataExport.Response> {
        let requestID = UUID().uuidString
        return await send(
            requestName: SentinelAIDataExport.requestName,
            responseName: SentinelAIDataExport.responseName,
            requestID: requestID,
            userInfo: SentinelAIDataExport.requestUserInfo(requestID: requestID, destinationPath: destinationPath),
            timeout: timeout,
            parse: SentinelAIDataExport.parseResponse
        )
    }

    func requestImportAIData(
        path: String,
        confirmed: Bool,
        timeout: TimeInterval = 600
    ) async -> SentinelCoordinationResult<SentinelAIDataImport.Response> {
        let requestID = UUID().uuidString
        return await send(
            requestName: SentinelAIDataImport.requestName,
            responseName: SentinelAIDataImport.responseName,
            requestID: requestID,
            userInfo: SentinelAIDataImport.requestUserInfo(requestID: requestID, path: path, confirmed: confirmed),
            timeout: timeout,
            parse: SentinelAIDataImport.parseResponse
        )
    }

    func requestPrepareForRollback(
        targetBrowserVersion: String,
        fromBrowserVersion: String?,
        operationID: String,
        timeout: TimeInterval = 120
    ) async -> SentinelCoordinationResult<SentinelPrepareForRollback.Response> {
        let requestID = UUID().uuidString
        return await send(
            requestName: SentinelPrepareForRollback.requestName,
            responseName: SentinelPrepareForRollback.responseName,
            requestID: requestID,
            userInfo: SentinelPrepareForRollback.requestUserInfo(
                requestID: requestID,
                targetBrowserVersion: targetBrowserVersion,
                fromBrowserVersion: fromBrowserVersion,
                operationID: operationID
            ),
            timeout: timeout,
            parse: SentinelPrepareForRollback.parseResponse
        )
    }

    private func send<Response>(
        requestName: Notification.Name,
        responseName: Notification.Name,
        requestID: String,
        userInfo: [String: String],
        timeout: TimeInterval,
        parse: @escaping ([String: String]) -> Response?
    ) async -> SentinelCoordinationResult<Response> {
        let state = SendState()
        return await withCheckedContinuation { (continuation: CheckedContinuation<SentinelCoordinationResult<Response>, Never>) in
            let subscription = transport.observe(name: responseName, object: sentinelBundleID) { info in
                guard info["requestID"] == requestID else { return }
                guard let response = parse(info) else { return }
                state.resolveOnce {
                    continuation.resume(returning: .response(response))
                }
            }
            state.attach(subscription)

            // Centralized browserBundleID injection: every request carries the
            // current browser bundle id so Sentinel can validate the sender.
            var payload = userInfo
            if !browserBundleID.isEmpty {
                payload["browserBundleID"] = browserBundleID
            }
            transport.post(name: requestName, object: sentinelBundleID, userInfo: payload)

            let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                state.resolveOnce {
                    continuation.resume(returning: .timedOut)
                }
            }
        }
    }
}

// MARK: - Export coordination

struct AIDataExportCoordinator {
    enum Result: Equatable {
        case packed(tarURL: URL)
        case skippedBrowserOnly(reason: SkipReason)
    }

    enum SkipReason: Equatable {
        case sentinelUnavailable
        case timedOut
        case exportFailed
        case cancelled
    }

    let ensureSentinelRunning: () async -> Bool
    let requestExport: (_ destinationPath: String) async -> SentinelCoordinationResult<SentinelAIDataExport.Response>
    let fileExists: (String) -> Bool
    let isCancelled: () -> Bool

    func coordinate(destinationTarURL: URL) async -> Result {
        if isCancelled() { return .skippedBrowserOnly(reason: .cancelled) }
        guard await ensureSentinelRunning() else {
            return .skippedBrowserOnly(reason: .sentinelUnavailable)
        }
        if isCancelled() { return .skippedBrowserOnly(reason: .cancelled) }

        switch await requestExport(destinationTarURL.path) {
        case .timedOut:
            return .skippedBrowserOnly(reason: .timedOut)
        case .response(let response):
            switch response.status {
            case .completed:
                guard let path = response.path, fileExists(path) else {
                    return .skippedBrowserOnly(reason: .exportFailed)
                }
                return .packed(tarURL: URL(fileURLWithPath: path))
            case .error:
                return .skippedBrowserOnly(reason: .exportFailed)
            }
        }
    }
}

/// Guards a single continuation resume and tears the observer down exactly once,
/// even when a response arrives before `attach` runs.
private final class SendState {
    private let lock = NSLock()
    private var resolved = false
    private var subscription: SentinelNotificationSubscription?

    func attach(_ subscription: SentinelNotificationSubscription) {
        lock.lock()
        if resolved {
            lock.unlock()
            subscription.cancel()
            return
        }
        self.subscription = subscription
        lock.unlock()
    }

    func resolveOnce(_ body: () -> Void) {
        lock.lock()
        if resolved {
            lock.unlock()
            return
        }
        resolved = true
        let subscription = self.subscription
        self.subscription = nil
        lock.unlock()
        subscription?.cancel()
        body()
    }
}
