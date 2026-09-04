// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import CocoaLumberjack
import CocoaLumberjackSwift

struct PhiLogging {
    /// Snapshots every retained log file without truncating or removing its contents.
    static func applicationLogFiles(log: DDLog = .sharedInstance) -> [(filename: String, data: Data)] {
        // Include queued messages, especially the reauthentication-required trace.
        log.flushLog()
        guard let fileLogger = log.allLoggers.first(where: { $0 is DDFileLogger }) as? DDFileLogger else {
            return []
        }

        return fileLogger.logFileManager.sortedLogFilePaths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            do {
                return (filename: url.lastPathComponent, data: try Data(contentsOf: url))
            } catch {
                AppLogError("Unable to read log file for attachment: \(path): \(error.localizedDescription)")
                return nil
            }
        }
    }

    static func applicationLog(maxLength length: Int) -> String? {
        guard let fileLogger = DDLog.sharedInstance.allLoggers.first(where: { $0 is DDFileLogger }) as? DDFileLogger else {
            return nil
        }
        let manager = fileLogger.logFileManager
        let logFiles = manager.sortedLogFilePaths
        var logEntries = ""
        var charsLeftToRead = length
        
        var index = 0
        while charsLeftToRead > 0 && index < logFiles.count {
            autoreleasepool {
                let logFilePath = logFiles[index]
                do {
                    var logFileString = try String(contentsOfFile: logFilePath, encoding: .utf8)
                    let nsString = logFileString as NSString
                    let fileLength = nsString.length
                    
                    if fileLength > charsLeftToRead {
                        var start = 0
                        var end = 0
                        let cutIndex = fileLength - charsLeftToRead
                        var cut = cutIndex
                        nsString.getLineStart(&start, end: &end, contentsEnd: nil, for: NSRange(location: cutIndex, length: 0))
                        if start < cutIndex {
                            // Move forward to the next full line to avoid truncation.
                            cut = end
                        }
                        logFileString = nsString.substring(from: cut)
                        charsLeftToRead = 0
                    } else {
                        charsLeftToRead -= fileLength
                    }
                    
                    // Prepend older files so the final output stays chronological.
                    logEntries.insert(contentsOf: logFileString, at: logEntries.startIndex)
                } catch {
                    AppLogError("Unable to read log file: \(logFilePath)")
                }
            }
            index += 1
        }
        
        return logEntries
    }
}
// Default log level for the app.
public let DDDefaultLogLevel: DDLogLevel = .error

private enum PhiLoggingInstallation {
    static var didInstall = false
}

/// Installs file + OS loggers once. Call `[PhiLoggingRuntime installSharedLogging]` from `main.m` before any Objective-C
/// `AppLog*` / `DDLog*`; `applicationWillFinishLaunching` also calls this as a fallback.
/// Repeat calls are no-ops so `DDFileLogger` is never torn down (which would roll the current file).
public func setupLogging() {
    if PhiLoggingInstallation.didInstall { return }

    let consoleLogger = DDOSLogger.sharedInstance
    consoleLogger.logFormatter = PhiLogFormatter()
    
    let fileManager = DDLogFileManagerDefault(logsDirectory: getLogsDirectory())
    let fileLogger = DDFileLogger(logFileManager: fileManager)
    fileLogger.rollingFrequency = -1 // Rotate by file size only.
    fileLogger.logFileManager.maximumNumberOfLogFiles = 7
    fileLogger.maximumFileSize = 5 * 1024 * 1024
    fileLogger.logFormatter = PhiLogFormatter()
#if DEBUG
    DDLog.add(fileLogger, with: .all)
    DDLog.add(consoleLogger, with: .all)
#else
    DDLog.add(fileLogger, with: .info)
    DDLog.add(consoleLogger, with: .info)
#endif
    PhiLoggingInstallation.didInstall = true
}

/// Entry point for Objective-C (`main.m`, Chromium launcher) so logging is installed before any `AppLog*`
/// or `DDLog*` calls. Swift global functions are not visible to ObjC; use this instead of calling
/// `setupLogging()` from `.m` files.
@objc(PhiLoggingRuntime)
public final class PhiLoggingRuntime: NSObject {
    @objc public static func installSharedLogging() {
        setupLogging()
    }
}

/// Returns the app log directory.
private func getLogsDirectory() -> String {
    let phiDataDir = FileSystemUtils.phiBrowserDataDirectory()
    return (phiDataDir as NSString)
        .appendingPathComponent("PhiLogs")
}

// MARK: - Public Logging Functions
public func AppLogInfo(_ logText: @autoclosure() -> String, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    DDLogInfo("\(logText())", file: file, function: function, line: line)
}

public func AppLogError(_ logText: @autoclosure() -> String, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    DDLogError("\(logText())", file: file, function: function, line: line)
}

public func AppLogWarn(_ logText: @autoclosure() -> String, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    DDLogWarn("\(logText())", file: file, function: function, line: line)
}

public func AppLogDebug(_ logText: @autoclosure() -> String, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    DDLogDebug("\(logText())", file: file, function: function, line: line)
}

public func AppLogVerbose(_ logText: @autoclosure() -> String, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    DDLogVerbose("\(logText())", file: file, function: function, line: line)
}

// MARK: - Convenience Logging Functions

/// Logs a user action.
public func AppLogUserAction(_ action: String, details: String? = nil, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    let message = details != nil ? "\(action) - \(details!)" : action
    DDLogInfo("👤 \(message)", file: file, function: function, line: line)
}

/// Logs a network request.
public func AppLogNetwork(_ method: String, url: String, statusCode: Int? = nil, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    let status = statusCode != nil ? " [\(statusCode!)]" : ""
    DDLogInfo("🌐 \(method) \(url)\(status)", file: file, function: function, line: line)
}

/// Logs a performance measurement.
public func AppLogPerformance(_ operation: String, duration: TimeInterval, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    DDLogInfo("⏱️ \(operation) took \(String(format: "%.3f", duration))s", file: file, function: function, line: line)
}

/// Logs a memory warning.
public func AppLogMemoryWarning(_ message: String = "Memory warning received", file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    DDLogWarn("🧠 \(message)", file: file, function: function, line: line)
}

// MARK: - SharedAuthTokenStore Bridge

/// Routes diagnostics from the shared (between Phi and Sentinel) keychain
/// store into Phi's `AppLog*` facade. Set `SharedAuthTokenStore.shared.logDelegate
/// = SharedAuthTokenStoreLogBridge.shared` once at startup before any auth-related
/// flow runs (login, renew, recovery), and the store's keychain errors will
/// land in the same CocoaLumberjack-backed log file as everything else.
final class SharedAuthTokenStoreLogBridge: SharedAuthTokenStoreLogDelegate {
    static let shared = SharedAuthTokenStoreLogBridge()

    private init() {}

    func sharedAuthTokenStore(
        _ store: SharedAuthTokenStore,
        log level: SharedAuthTokenStoreLogLevel,
        _ message: String
    ) {
        switch level {
        case .info:
            AppLogInfo(message)
        case .warning:
            AppLogWarn(message)
        case .error:
            AppLogError(message)
        }
    }
}
