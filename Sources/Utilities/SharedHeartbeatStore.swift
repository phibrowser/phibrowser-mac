// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

final class SharedHeartbeatStore {
    static let shared = SharedHeartbeatStore()

    private let fileURL: URL = {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.phibrowser.shared"
        ) else {
            fatalError("App Group 'group.com.phibrowser.shared' is not configured in entitlements")
        }
        #if NIGHTLY_BUILD
        let filename = ".phi-heartbeat-canary"
        #else
        let filename = ".phi-heartbeat"
        #endif
        return groupURL.appendingPathComponent(filename)
    }()

    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {}

    func write() {
        let dateString = formatter.string(from: Date())
        guard let data = dateString.data(using: .utf8) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func read() -> Date? {
        guard let data = try? Data(contentsOf: fileURL),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return formatter.date(from: string)
    }
}
