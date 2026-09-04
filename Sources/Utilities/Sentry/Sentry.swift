// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Sentry

enum TimeMachineSentryTrace: Codable, Equatable {
    case backup(TimeMachineBackupTrace)
    case restorePreparation(TimeMachineRestorePreparationTrace)
    case restoreRecovery(TimeMachineRestoreRecoveryTrace)

    private enum CodingKeys: String, CodingKey {
        case kind
        case backup
        case restorePreparation
        case restoreRecovery
    }

    private enum Kind: String, Codable {
        case backup
        case restorePreparation
        case restoreRecovery
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .backup:
            self = .backup(try container.decode(TimeMachineBackupTrace.self, forKey: .backup))
        case .restorePreparation:
            self = .restorePreparation(
                try container.decode(TimeMachineRestorePreparationTrace.self, forKey: .restorePreparation)
            )
        case .restoreRecovery:
            self = .restoreRecovery(
                try container.decode(TimeMachineRestoreRecoveryTrace.self, forKey: .restoreRecovery)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .backup(let trace):
            try container.encode(Kind.backup, forKey: .kind)
            try container.encode(trace, forKey: .backup)
        case .restorePreparation(let trace):
            try container.encode(Kind.restorePreparation, forKey: .kind)
            try container.encode(trace, forKey: .restorePreparation)
        case .restoreRecovery(let trace):
            try container.encode(Kind.restoreRecovery, forKey: .kind)
            try container.encode(trace, forKey: .restoreRecovery)
        }
    }
}

struct TimeMachineSentryTraceStore {
    private static let maxStoredTraceCount = 100

    private let queueURL: URL
    private let fileManager: FileManager

    init(paths: TimeMachinePaths = TimeMachinePaths(), fileManager: FileManager = .default) {
        self.init(queueURL: paths.sentryTraceQueueURL, fileManager: fileManager)
    }

    init(queueURL: URL, fileManager: FileManager = .default) {
        self.queueURL = queueURL
        self.fileManager = fileManager
    }

    func append(_ trace: TimeMachineSentryTrace) throws {
        var traces = (try? load()) ?? []
        traces.append(trace)
        if traces.count > Self.maxStoredTraceCount {
            traces = Array(traces.suffix(Self.maxStoredTraceCount))
        }
        try write(traces)
    }

    func drain() throws -> [TimeMachineSentryTrace] {
        guard fileManager.fileExists(atPath: queueURL.path) else {
            return []
        }
        defer {
            try? fileManager.removeItem(at: queueURL)
        }
        return try load()
    }

    private func load() throws -> [TimeMachineSentryTrace] {
        let data = try Data(contentsOf: queueURL)
        return try Self.decoder.decode([TimeMachineSentryTrace].self, from: data)
    }

    private func write(_ traces: [TimeMachineSentryTrace]) throws {
        let directoryURL = queueURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(traces)
        try data.write(to: queueURL, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        JSONDecoder()
    }
}

@objc class SentryService: NSObject {
    static let maxSentryLogSize: UInt = 98000
    static let maxAuthReauthenticationSentryLogSize: UInt = 1024 * 1024
    private static var hasStarted = false
    private static var isStarting = false
    private static let pendingTimeMachineTraceLock = NSLock()
    private static var pendingTimeMachineTraces: [TimeMachineSentryTrace] = []
    private static var timeMachineTraceStore = TimeMachineSentryTraceStore()

    @objc static func setup() {
        pendingTimeMachineTraceLock.lock()
        guard !hasStarted, !isStarting else {
            pendingTimeMachineTraceLock.unlock()
            return
        }
        isStarting = true
        pendingTimeMachineTraceLock.unlock()

        SentrySDK.start { options in
            options.dsn = ""
            options.enableLogs = true
            
            if let basePath = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first,
               let appName = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String {
                options.cacheDirectoryPath = (basePath as NSString).appendingPathComponent(appName)
            }
            
            // https://docs.sentry.io/platforms/apple/guides/macos/usage/#capturing-uncaught-exceptions-in-macos
            options.enableUncaughtNSExceptionReporting = true
            options.enableNetworkBreadcrumbs = false
            options.enableAutoBreadcrumbTracking = false
            
            options.tracesSampleRate = 0.2
            options.enableCoreDataTracing = false
            options.enableFileIOTracing = false
            options.enableNetworkTracking = false
            options.enableAutoSessionTracking = true
            options.enableCaptureFailedRequests = false
            options.enableAutoPerformanceTracing = false
            options.enableAppHangTracking = false
            options.enableMetricKit = true
            options.enableMetricKitRawPayload = true
            
            options.beforeSend = { event in
                let isMetricKitDiskWrite =
                event.exceptions?.contains {
                    $0.type == "MXDiskWriteException" ||
                    $0.type == "MXDiskWriteExceptionDiagnostic"
                } == true
                
                if isMetricKitDiskWrite {
                    return nil
                }
                
                return event
            }
            
            options.initialScope = { scope in
                // Attach recent logs up front because startup may immediately report a previous crash.
                scope.clearAttachments()
                if let stringData = PhiLogging.applicationLog(maxLength: Int(maxSentryLogSize))?.data(using: .utf8) {
                    let attachment = Attachment(data: stringData, filename: "logs.txt")
                    scope.addAttachment(attachment)
                }
                return scope
            }
            
#if DEBUG
            options.debug = true
            //      options.enableSpotlight = true
            options.environment = "debug"
#elseif NIGHTLY_BUILD
            // Sentry release names cannot contain `/`.
            let shortVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
                .replacingOccurrences(of: "/", with: "-")
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
            // Use `package@version+build` so build-level filtering stays available.
            options.releaseName = "nightly@\(shortVersion)+\(build)"
            
            options.environment = "nightly"
#else
            let shortVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
                .replacingOccurrences(of: "/", with: "-")
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
            options.environment = "ddl"
            options.releaseName = "release@\(shortVersion)+\(build)"
#endif
        }

        let pendingTimeMachineTraces: [TimeMachineSentryTrace]
        let traceStoreDrainError: Error?
        pendingTimeMachineTraceLock.lock()
        hasStarted = true
        isStarting = false
        do {
            pendingTimeMachineTraces = try timeMachineTraceStore.drain() + self.pendingTimeMachineTraces
            traceStoreDrainError = nil
        } catch {
            pendingTimeMachineTraces = self.pendingTimeMachineTraces
            traceStoreDrainError = error
        }
        self.pendingTimeMachineTraces.removeAll()
        pendingTimeMachineTraceLock.unlock()

        if let traceStoreDrainError {
            AppLogError("[TimeMachine] Failed to drain pending Sentry traces: \(traceStoreDrainError.localizedDescription)")
        }
        configureUser(AccountController.shared.account)
        flushPendingTimeMachineTraces(pendingTimeMachineTraces)
    }
    
    static func configureUser(_ account: Account?) {
        guard hasStarted else { return }
        guard ChromiumLauncher.sharedInstance().bridge?.isMetricsReportingEnabled() ?? false,
              let userInfo = account?.userInfo,
              let sub = userInfo.sub else {
            SentrySDK.setUser(nil)
            return
        }
        
        let user = Sentry.User()
        user.email = userInfo.email
        user.userId = sub
        user.username = userInfo.name
        SentrySDK.setUser(user)
    }

    static func captureAuthReauthenticationRequired(
        reason: String,
        incidentID: String,
        trace: String,
        attributes: [String: String]
    ) {
        var enrichedAttributes = attributes
        enrichedAttributes["reason"] = reason
        enrichedAttributes["incidentID"] = incidentID

        SentrySDK.capture(message: "Auth reauthentication required: \(reason)") { scope in
            scope.setLevel(.warning)
            scope.setTag(value: "auth", key: "area")
            scope.setTag(value: "reauthentication", key: "auth.operation")
            scope.setTag(value: reason, key: "auth.reason")
            scope.setTag(value: "required", key: "auth.reauthentication.state")
            scope.setTag(value: incidentID, key: "auth.reauthentication.id")
            scope.setContext(value: enrichedAttributes, key: "auth_reauthentication")
            scope.setExtra(value: trace, key: "auth_trace")

            // Replace the inherited startup log excerpt with complete, current log files.
            scope.clearAttachments()
            if let data = trace.data(using: .utf8) {
                scope.addAttachment(Attachment(data: data, filename: "auth-trace.txt"))
            }
            if let sentinelLogData = SentinelHelper.recentBootLog() {
                scope.addAttachment(Attachment(data: sentinelLogData, filename: "sentinel-boot.log"))
            }
            for logFile in PhiLogging.applicationLogFiles() {
                scope.addAttachment(Attachment(data: logFile.data, filename: logFile.filename))
            }
        }
    }

    static func captureAuthReauthenticationResult(
        succeeded: Bool,
        reason: String,
        incidentID: String,
        trace: String,
        attributes: [String: String]
    ) {
        var enrichedAttributes = attributes
        enrichedAttributes["reason"] = reason
        enrichedAttributes["result"] = succeeded ? "success" : "failure"
        enrichedAttributes["incidentID"] = incidentID

        if !succeeded {
            SentrySDK.logger.error("Auth reauthentication failed", attributes: enrichedAttributes)
        }

        let result = succeeded ? "succeeded" : "failed"
        SentrySDK.capture(message: "Auth reauthentication \(result): \(reason)") { scope in
            scope.setLevel(succeeded ? .info : .error)
            scope.setTag(value: "auth", key: "area")
            scope.setTag(value: "reauthentication", key: "auth.operation")
            scope.setTag(value: reason, key: "auth.reason")
            scope.setTag(value: result, key: "auth.reauthentication.result")
            scope.setTag(value: incidentID, key: "auth.reauthentication.id")
            scope.setContext(value: enrichedAttributes, key: "auth_reauthentication")
            scope.setExtra(value: trace, key: "auth_trace")
            if let data = trace.data(using: .utf8) {
                scope.addAttachment(Attachment(data: data, filename: "auth-trace.txt"))
            }
            if let sentinelLogData = SentinelHelper.recentBootLog() {
                scope.addAttachment(Attachment(data: sentinelLogData, filename: "sentinel-boot.log"))
            }
            if let logData = PhiLogging.applicationLog(maxLength: Int(maxAuthReauthenticationSentryLogSize))?
                .data(using: .utf8) {
                scope.addAttachment(Attachment(data: logData, filename: "logs.txt"))
            }
        }
    }

    static func captureTimeMachineBackupTrace(_ trace: TimeMachineBackupTrace) {
        if bufferPendingTimeMachineTrace(.backup(trace)) {
            return
        }

        var context: [String: Any] = [
            "result": trace.result.rawValue,
            "backup_id": trace.backupID.uuidString,
            "bundle_identifier": trace.bundleIdentifier,
            "current_version": trace.currentVersion,
            "current_build": trace.currentBuild,
            "backup_trigger_build": trace.backupTriggerBuild,
            "rollback_version": trace.rollbackVersion,
            "rollback_build": trace.rollbackBuild,
            "scope": timeMachineScopeDescription(trace.includeChromiumData),
            "include_chromium_data": trace.includeChromiumData,
            "duration_ms": durationMilliseconds(trace.duration),
            "duration_seconds": trace.duration
        ]
        if let snapshotSizeBytes = trace.snapshotSizeBytes {
            context["snapshot_size_bytes"] = NSNumber(value: snapshotSizeBytes)
        }
        if let errorDescription = trace.errorDescription {
            context["error_description"] = errorDescription
        }
        if let errorType = trace.errorType {
            context["error_type"] = errorType
        }

        captureTimeMachineTrace(
            message: "Time Machine backup \(trace.result.rawValue)",
            level: trace.result == .succeeded ? .info : .error,
            operation: "backup",
            result: trace.result.rawValue,
            scope: timeMachineScopeDescription(trace.includeChromiumData),
            stage: nil,
            context: context
        )
    }

    static func captureTimeMachineRestorePreparationTrace(_ trace: TimeMachineRestorePreparationTrace) {
        if bufferPendingTimeMachineTrace(.restorePreparation(trace)) {
            return
        }

        var context: [String: Any] = [
            "result": trace.result.rawValue,
            "operation_id": trace.operationID.uuidString,
            "backup_id": trace.backupID.uuidString,
            "bundle_identifier": trace.bundleIdentifier,
            "rollback_version": trace.rollbackVersion,
            "rollback_build": trace.rollbackBuild,
            "scope": timeMachineScopeDescription(trace.includeChromiumData),
            "include_chromium_data": trace.includeChromiumData,
            "duration_ms": durationMilliseconds(trace.duration),
            "duration_seconds": trace.duration,
            "last_stage": trace.lastStage.rawValue
        ]
        if let packageSizeBytes = trace.packageSizeBytes {
            context["package_size_bytes"] = NSNumber(value: packageSizeBytes)
        }
        if let operationSizeBytes = trace.operationSizeBytes {
            context["operation_size_bytes"] = NSNumber(value: operationSizeBytes)
        }
        if let errorDescription = trace.errorDescription {
            context["error_description"] = errorDescription
        }
        if let errorType = trace.errorType {
            context["error_type"] = errorType
        }

        captureTimeMachineTrace(
            message: "Time Machine restore preparation \(trace.result.rawValue)",
            level: trace.result == .succeeded ? .info : .error,
            operation: "restore_prepare",
            result: trace.result.rawValue,
            scope: timeMachineScopeDescription(trace.includeChromiumData),
            stage: trace.lastStage.rawValue,
            context: context
        )
    }

    static func captureTimeMachineRestoreRecoveryTrace(_ trace: TimeMachineRestoreRecoveryTrace) {
        if bufferPendingTimeMachineTrace(.restoreRecovery(trace)) {
            return
        }

        var context: [String: Any] = [
            "status": trace.status.rawValue,
            "bundle_identifier": trace.bundleIdentifier
        ]
        if let operationID = trace.operationID {
            context["operation_id"] = operationID.uuidString
        }
        if let phase = trace.phase {
            context["phase"] = phase.rawValue
        }
        if let hasStartedDestructiveSwap = trace.hasStartedDestructiveSwap {
            context["has_started_destructive_swap"] = hasStartedDestructiveSwap
        }
        if let reason = trace.reason {
            context["reason"] = reason
        }
        if let errorDescription = trace.errorDescription {
            context["error_description"] = errorDescription
        }
        if let errorType = trace.errorType {
            context["error_type"] = errorType
        }

        captureTimeMachineTrace(
            message: "Time Machine restore recovery \(trace.status.rawValue)",
            level: timeMachineRecoveryLevel(for: trace.status),
            operation: "restore_recovery",
            result: trace.status.rawValue,
            scope: nil,
            stage: trace.phase?.rawValue,
            context: context
        )
    }

    static func captureMemoryThresholdExceeded(snapshot: MemoryUsageSnapshot) {
        SentrySDK.capture(message: "Phi memory usage threshold exceeded") { scope in
            scope.setLevel(.warning)
            scope.setTag(value: "memory", key: "area")
            scope.setTag(value: "exceeded", key: "memory.threshold")
            scope.setContext(value: snapshot.sentryContext, key: "memory_usage")

            scope.clearAttachments()
            if let stringData = PhiLogging.applicationLog(maxLength: Int(maxSentryLogSize))?.data(using: .utf8) {
                scope.addAttachment(Attachment(data: stringData, filename: "logs.txt"))
            }
        }
    }

    static func captureSentinelVersionGuardWarning(_ warning: SentinelVersionGuardWarning) {
        let message: String
        let diagnostic: String
        let runningStatus: String
        let versionMatch: String
        let context: [String: Any]

        switch warning {
        case .notRunning(let browserBundleID, let browserVersion, let sentinelBundleID):
            message = "Sentinel is not running after startup recovery"
            diagnostic = "not_running"
            runningStatus = "false"
            versionMatch = "unknown"
            context = [
                "browser_bundle_id": browserBundleID,
                "browser_version": browserVersion,
                "sentinel_bundle_id": sentinelBundleID,
                "is_running": false,
                "version_match": versionMatch
            ]
        case .versionMismatch(let snapshot):
            message = "Phi and Sentinel versions do not match"
            diagnostic = "version_mismatch"
            runningStatus = "true"
            versionMatch = "false"
            context = [
                "browser_bundle_id": snapshot.browserBundleID,
                "browser_version": snapshot.browserVersion,
                "sentinel_bundle_id": snapshot.sentinelBundleID,
                "sentinel_version": snapshot.sentinelVersion,
                "is_running": true,
                "version_match": versionMatch
            ]
        }

        SentrySDK.capture(message: message) { scope in
            scope.setLevel(.warning)
            scope.setTag(value: "sentinel", key: "area")
            scope.setTag(value: diagnostic, key: "sentinel.diagnostic")
            scope.setTag(value: runningStatus, key: "sentinel.running")
            scope.setTag(value: versionMatch, key: "sentinel.version_match")
            scope.setContext(value: context, key: "sentinel")
        }
    }

    private static func bufferPendingTimeMachineTrace(_ trace: TimeMachineSentryTrace) -> Bool {
        pendingTimeMachineTraceLock.lock()
        defer {
            pendingTimeMachineTraceLock.unlock()
        }

        guard !hasStarted else {
            return false
        }

        do {
            try timeMachineTraceStore.append(trace)
        } catch {
            pendingTimeMachineTraces.append(trace)
            AppLogError("[TimeMachine] Failed to persist pending Sentry trace: \(error.localizedDescription)")
        }
        return true
    }

    private static func flushPendingTimeMachineTraces(_ traces: [TimeMachineSentryTrace]) {
        for trace in traces {
            switch trace {
            case .backup(let backupTrace):
                captureTimeMachineBackupTrace(backupTrace)
            case .restorePreparation(let restorePreparationTrace):
                captureTimeMachineRestorePreparationTrace(restorePreparationTrace)
            case .restoreRecovery(let restoreRecoveryTrace):
                captureTimeMachineRestoreRecoveryTrace(restoreRecoveryTrace)
            }
        }
    }

    private static func captureTimeMachineTrace(
        message: String,
        level: SentryLevel,
        operation: String,
        result: String,
        scope: String?,
        stage: String?,
        context: [String: Any]
    ) {
        guard hasStarted else {
            return
        }

        SentrySDK.capture(message: message) { sentryScope in
            sentryScope.setLevel(level)
            sentryScope.setTag(value: "time_machine", key: "area")
            sentryScope.setTag(value: operation, key: "time_machine.operation")
            sentryScope.setTag(value: result, key: "time_machine.result")
            if let scope {
                sentryScope.setTag(value: scope, key: "time_machine.scope")
            }
            if let stage {
                sentryScope.setTag(value: stage, key: "time_machine.stage")
            }
            sentryScope.setContext(value: context, key: "time_machine")
        }
    }

    private static func timeMachineRecoveryLevel(for status: TimeMachineRestoreRecoveryTrace.Status) -> SentryLevel {
        switch status {
        case .launched:
            return .info
        case .markedFailed:
            return .warning
        case .blocked, .inspectionFailed:
            return .error
        }
    }

    private static func timeMachineScopeDescription(_ includeChromiumData: Bool) -> String {
        includeChromiumData ? "full" : "phi-only"
    }

    private static func durationMilliseconds(_ duration: TimeInterval) -> Int {
        Int((max(0, duration) * 1_000).rounded())
    }
}
