// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
import Foundation

enum ServiceBrokerSocketPath {
    static func sentinelBundleIdentifier(browserBundleIdentifier: String) -> String {
        let identifier = browserBundleIdentifier.lowercased()
        if identifier.contains("canary") {
            return "com.phibrowser.canary.Sentinel"
        }
        if identifier.contains("dev") {
            return "com.phibrowser.dev.Sentinel"
        }
        return "com.phibrowser.Sentinel"
    }

    static func sanitizePathComponent(_ component: String) -> String {
        var result = component
        for character in ["/", ":", "|", "\\", "*", "?", "\"", "<", ">"] {
            result = result.replacingOccurrences(of: character, with: "_")
        }
        return result
    }

    static func sentinelStoragePath(
        applicationSupportPath: String,
        browserBundleIdentifier: String,
        auth0Subject: String
    ) -> String {
        let sentinelPath = (applicationSupportPath as NSString).appendingPathComponent(
            sentinelBundleIdentifier(browserBundleIdentifier: browserBundleIdentifier)
        )
        return (sentinelPath as NSString).appendingPathComponent(
            sanitizePathComponent(auth0Subject)
        )
    }

    static func dataSocketPath(storagePath: String) -> String {
        let digest = SHA256.hash(data: Data(storagePath.utf8))
        let shortHash = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "/tmp/phi-sentinel-\(shortHash)/sockets/service-broker.sock"
    }
}
