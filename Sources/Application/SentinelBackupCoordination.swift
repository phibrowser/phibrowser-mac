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

    static func requestUserInfo(requestID: String, targetBrowserVersion: String, fromBrowserVersion: String, operationID: String) -> [String: String] {
        ["requestID": requestID, "targetBrowserVersion": targetBrowserVersion, "fromBrowserVersion": fromBrowserVersion, "operationID": operationID]
    }

    static func parseResponse(_ info: [String: String]) -> Response? {
        guard let raw = info["status"], let status = Response.Status(rawValue: raw) else { return nil }
        return Response(status: status)
    }
}
