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

    /// Reports an unrecoverable auth failure (refresh-token reuse, token-family destruction,
    /// missing credentials) that forced the user back to the login state. Sends one Sentry
    /// message event with the rendered auth trace attached. Callers (`AuthManager`) MUST
    /// dedupe to avoid producing one event per concurrent caller observing the same
    /// failure. The previous implementation also opened a manual `auth.forced-logout`
    /// transaction, but transactions are intended for timing/spans and bypass `tracesSampleRate`,
    /// which would noisify the performance dashboard for what is a discrete error event.
    static func captureAuthForcedLogout(
        operation: String,
        reason: String,
        trace: String,
        attributes: [String: String]
    ) {
        var enrichedAttributes = attributes
        enrichedAttributes["operation"] = operation
        enrichedAttributes["reason"] = reason

        SentrySDK.logger.error("Auth forced logout", attributes: enrichedAttributes)

        SentrySDK.capture(message: "Auth forced logout: \(reason)") { scope in
            // `noCredentials` typically reflects a benign state (user wiped Keychain,
            // first-run, etc.) and should not page on-call.
            scope.setLevel(reason == "no_credentials" ? .warning : .error)
            scope.setTag(value: "auth", key: "area")
            scope.setTag(value: reason, key: "auth.reason")
            scope.setTag(value: operation, key: "auth.operation")
            scope.setContext(value: enrichedAttributes, key: "auth")
            scope.setExtra(value: trace, key: "auth_trace")
            if let data = trace.data(using: .utf8) {
                scope.addAttachment(Attachment(data: data, filename: "auth-trace.txt"))
            }
            // Sentinel can trigger `ferrt` while Phi is closed (the renew runs
            // out-of-process every few minutes when Phi is offline). Attaching
            // the tail of Sentinel's `boot.log` lets post-mortem see the
            // out-of-process events that led up to the logout, which Phi's
            // own auth trace cannot capture.
            if let sentinelLogData = SentinelHelper.recentBootLog() {
                scope.addAttachment(Attachment(data: sentinelLogData, filename: "sentinel-boot.log"))
            }
        }
    }
}
