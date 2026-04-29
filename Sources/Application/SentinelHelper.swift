// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import ServiceManagement
import CocoaLumberjackSwift

enum SentinelHelper {

    static func register() {
        let identifier = loginItemIdentifier()
        let service = SMAppService.loginItem(identifier: identifier)
        AppLogInfo("Sentinel login item identifier: \(identifier)")
        AppLogInfo("Sentinel login item status before register: \(service.status)")

        do {
            try service.register()
            AppLogInfo("Sentinel login item status after register: \(service.status)")
        } catch {
            AppLogError(error.localizedDescription)
        }
    }

    static func unregister() async {
        let identifier = loginItemIdentifier()
        let service = SMAppService.loginItem(identifier: identifier)
        do {
            try await service.unregister()
            AppLogInfo("Sentinel login item unregistered, status: \(service.status)")
        } catch {
            AppLogError("Failed to unregister Sentinel: \(error.localizedDescription)")
        }
    }

    static var isRunning: Bool {
        let identifier = loginItemIdentifier()
        return NSWorkspace.shared.runningApplications.contains {
            guard let bundleID = $0.bundleIdentifier else { return false }
            return bundleID.caseInsensitiveCompare(identifier) == .orderedSame && !$0.isTerminated
        }
    }

    static func launch() {
        ensureRunning(identifier: loginItemIdentifier())
    }

    static func terminate() {
        let identifier = loginItemIdentifier()
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  bundleID.caseInsensitiveCompare(identifier) == .orderedSame,
                  !app.isTerminated else { continue }
            app.terminate()
            AppLogInfo("Sent terminate signal to Sentinel (pid \(app.processIdentifier))")
        }
    }

    static func terminateAll() {
        let identifiers: Set<String> = [loginItemIdentifier()]
        for app in NSWorkspace.shared.runningApplications.filter({ identifiers.contains($0.bundleIdentifier ?? "") }) {
            guard !app.isTerminated else { continue }
            app.terminate()
            AppLogInfo("Sent terminate signal to Sentinel (pid \(app.processIdentifier), bundleID \(app.bundleIdentifier ?? ""))")
        }
    }

    private static func loginItemIdentifier() -> String {
        let mainBundleID = Bundle.main.bundleIdentifier?.lowercased() ?? ""
        if mainBundleID.contains("canary") {
            return "com.phibrowser.canary.Sentinel"
        }
        return "com.phibrowser.Sentinel"
    }

    private static func ensureRunning(identifier: String) {
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            guard let bundleID = $0.bundleIdentifier else { return false }
            return bundleID.caseInsensitiveCompare(identifier) == .orderedSame && !$0.isTerminated
        }

        if isRunning {
            AppLogInfo("Sentinel is already running")
            return
        }

        guard let sentinelURL = loginItemURL() else {
            AppLogError("Sentinel login item app not found in host bundle")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: sentinelURL, configuration: configuration) { app, error in
            if let error {
                AppLogError("Failed to launch Sentinel login item: \(error.localizedDescription)")
                return
            }

            if let app {
                AppLogInfo("Launched Sentinel login item with pid \(app.processIdentifier)")
            } else {
                AppLogInfo("Requested Sentinel login item launch")
            }
        }
    }

    private static func loginItemURL() -> URL? {
        let sentinelURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LoginItems", isDirectory: true)
            .appendingPathComponent("Phi Sentinel.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sentinelURL.path) else {
            return nil
        }
        return sentinelURL
    }

    // MARK: - Sentinel Log Reader

    /// Reads the tail of Sentinel's `boot.log` (the file Sentinel's
    /// `SentinelLogger` writes to) capped at `maxBytes`. Used to attach
    /// Sentinel's recent activity to Phi's forced-logout Sentry events,
    /// because the underlying `ferrt` is often triggered on the Sentinel
    /// side while Phi is closed and Phi otherwise has no visibility into
    /// what happened.
    ///
    /// Returns `nil` when:
    /// - Sentinel has never run on this device (file does not exist),
    /// - the log directory layout has changed without us updating the path
    ///   resolution below, or
    /// - the file system rejected the read (sandbox, permissions).
    static func recentBootLog(maxBytes: Int = 98_000) -> Data? {
        let url = bootLogURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = (attrs[.size] as? UInt64).map(Int.init),
              fileSize > 0 else {
            return nil
        }

        let bytesToRead = min(fileSize, maxBytes)
        let offset = UInt64(fileSize - bytesToRead)

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
            return try handle.readToEnd()
        } catch {
            AppLogError("[SentinelHelper] failed to read sentinel boot.log tail: \(error.localizedDescription)")
            return nil
        }
    }

    private static func bootLogURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(sentinelLogDirName(), isDirectory: true)
            .appendingPathComponent("boot.log", isDirectory: false)
    }

    /// Mirrors `SentinelLogger.logDirName` from the Sentinel project.
    /// Sentinel resolves its log directory from its OWN bundle ID; Phi's
    /// bundle ID has the same `.canary.` / `.dev.` channel markers, so we
    /// can derive the same directory name without any IPC.
    private static func sentinelLogDirName() -> String {
        let phiBundleID = Bundle.main.bundleIdentifier?.lowercased() ?? ""
        if phiBundleID.contains(".dev.") {
            return "PhiSentinel-Dev"
        }
        if phiBundleID.contains(".canary.") {
            return "PhiSentinel-Canary"
        }
        return "PhiSentinel"
    }
}
