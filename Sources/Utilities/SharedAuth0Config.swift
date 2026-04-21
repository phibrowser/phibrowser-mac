// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct Auth0Config {
    let domain: String
    let clientId: String
    let audience: String
}

final class SharedAuth0Config {
    static let shared = SharedAuth0Config()

    private let fileURL: URL = {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.phibrowser.shared"
        ) else {
            fatalError("App Group 'group.com.phibrowser.shared' is not configured in entitlements")
        }
        #if NIGHTLY_BUILD
        let filename = "auth0-config-canary.plist"
        #else
        let filename = "auth0-config.plist"
        #endif
        return groupURL.appendingPathComponent(filename)
    }()

    private init() {}

    func write(domain: String, clientId: String, audience: String) {
        let dict: [String: String] = [
            "Domain": domain,
            "ClientId": clientId,
            "Audience": audience
        ]
        let nsDict = dict as NSDictionary
        nsDict.write(to: fileURL, atomically: true)
    }

    func read() -> Auth0Config? {
        guard let dict = NSDictionary(contentsOf: fileURL) as? [String: String],
              let domain = dict["Domain"],
              let clientId = dict["ClientId"],
              let audience = dict["Audience"] else {
            return nil
        }
        return Auth0Config(domain: domain, clientId: clientId, audience: audience)
    }
}
