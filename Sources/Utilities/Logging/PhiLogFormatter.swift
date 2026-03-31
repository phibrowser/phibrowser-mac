// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import CocoaLumberjack
import CocoaLumberjackSwift

@objc(PhiLogFormatter)
class PhiLogFormatter: NSObject, DDLogFormatter {
    
    private let dateFormatter: DateFormatter
    
    override init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        dateFormatter.formatterBehavior = .behavior10_4
        super.init()
    }
    
    func format(message logMessage: DDLogMessage) -> String? {
        let timestamp = dateFormatter.string(from: logMessage.timestamp)
        let level = levelEmoji(for: logMessage.flag) + levelString(for: logMessage.flag)
        let threadInfo = threadString(for: logMessage)
        let fileInfo = fileString(for: logMessage)
        let message = logMessage.message
        
        return "[\(timestamp)] \(level) [\(threadInfo)] \(fileInfo) - \(message)"
    }
    
    // MARK: - Private Methods
    
    private func levelEmoji(for flag: DDLogFlag) -> String {
        switch flag {
        case .error:
            return "❌"
        case .warning:
            return "⚠️"
        case .info:
            return "ℹ️"
        case .debug:
            return "🐛"
        case .verbose:
            return "📝"
        default:
            return "📄"
        }
    }
    
    private func levelString(for flag: DDLogFlag) -> String {
        switch flag {
        case .error:
            return "E|***"
        case .warning:
            return "W|**"
        case .info:
            return "I|*"
        case .debug:
            return "D|"
        case .verbose:
            return "V|"
        default:
            return "D|"
        }
    }
    
    private func threadString(for logMessage: DDLogMessage) -> String {
        var result = ""
        
        result += "T:\(logMessage.threadID)"
        
        if let threadName = logMessage.threadName, !threadName.isEmpty {
            result += "|\(threadName)"
        }
        
        let queueLabel = logMessage.queueLabel
        if !queueLabel.isEmpty && queueLabel != "com.apple.main-thread" {
            let shortQueueLabel = queueLabel.components(separatedBy: ".").last ?? queueLabel
            result += "|\(shortQueueLabel)"
        }
        
        return result
    }
    
    private func fileString(for logMessage: DDLogMessage) -> String {
        let fileName = logMessage.fileName
        let function = logMessage.function ?? "unknown"
        let line = logMessage.line
        
        return "\(fileName):\(line) \(function)()"
    }
}

// MARK: - DDLogFormatter Optional Methods

extension PhiLogFormatter {
    
    func didAdd(to logger: DDLogger) {
    }
    
    func didAdd(to logger: DDLogger, in queue: DispatchQueue) {
    }
    
    func willRemove(from logger: DDLogger) {
    }
}
