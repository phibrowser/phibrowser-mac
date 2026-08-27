// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
import Darwin
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

    /// Data-socket path of the broker owned by the Sentinel that serves
    /// `auth0Subject` for this browser bundle. `nil` when the subject is empty
    /// or Application Support cannot be located.
    static func currentDataSocketPath(auth0Subject: String) -> String? {
        guard !auth0Subject.isEmpty,
              let applicationSupportPath = NSSearchPathForDirectoriesInDomains(
                  .applicationSupportDirectory,
                  .userDomainMask,
                  true
              ).first else {
            return nil
        }
        let storagePath = sentinelStoragePath(
            applicationSupportPath: applicationSupportPath,
            browserBundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            auth0Subject: auth0Subject
        )
        return dataSocketPath(storagePath: storagePath)
    }

    static func dataSocketPath(storagePath: String) -> String {
        let digest = SHA256.hash(data: Data(storagePath.utf8))
        let shortHash = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let shortRoot = "/tmp/phi-sentinel-\(shortHash)"
        let shortSocketDirectory = (shortRoot as NSString).appendingPathComponent("sockets")

        // Sentinel repairs permissions on owned, real directories before binding,
        // but falls back when either short-path component is poisoned. Predict the
        // same choice from the shared storage path so no extra discovery protocol
        // or credential-bearing probe is needed.
        if directoryTrust(atPath: shortRoot) == .unsafe
            || directoryTrust(atPath: shortSocketDirectory) == .unsafe {
            return (storagePath as NSString)
                .appendingPathComponent("state/sockets/service-broker.sock")
        }
        return (shortSocketDirectory as NSString).appendingPathComponent("service-broker.sock")
    }

    private enum DirectoryTrust {
        case missing
        case ownedDirectory
        case unsafe
    }

    private static func directoryTrust(atPath path: String) -> DirectoryTrust {
        var information = stat()
        guard lstat(path, &information) == 0 else {
            return errno == ENOENT ? .missing : .unsafe
        }
        guard information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == geteuid() else {
            return .unsafe
        }
        return .ownedDirectory
    }
}
