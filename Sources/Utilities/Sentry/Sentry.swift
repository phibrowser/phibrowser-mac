// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Sentry

@objc class SentryService: NSObject {
    static let maxSentryLogSize: UInt = 98000

    @objc static func setup() {
        SentrySDK.start { options in
            options.dsn = ""
            options.experimental.enableLogs = true
            
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
    }
    
    static func configureUser(_ account: Account) {
        guard let userInfo = account.userInfo else {
            return
        }
        
        let user = Sentry.User()
        user.email = userInfo.email
        user.userId = userInfo.sub
        user.username = userInfo.name
        SentrySDK.setUser(user)
    }

    static func captureAuthReauthenticationResult(
        succeeded: Bool,
        reason: String,
        trace: String,
        attributes: [String: String]
    ) {
        var enrichedAttributes = attributes
        enrichedAttributes["reason"] = reason
        enrichedAttributes["result"] = succeeded ? "success" : "failure"

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
            scope.setContext(value: enrichedAttributes, key: "auth_reauthentication")
            scope.setExtra(value: trace, key: "auth_trace")
            if let data = trace.data(using: .utf8) {
                scope.addAttachment(Attachment(data: data, filename: "auth-trace.txt"))
            }
            if let sentinelLogData = SentinelHelper.recentBootLog() {
                scope.addAttachment(Attachment(data: sentinelLogData, filename: "sentinel-boot.log"))
            }
        }
    }
}
