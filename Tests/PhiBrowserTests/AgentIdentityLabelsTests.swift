// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The Settings lists decode grants and denials from keys alone; these prove
/// they read back the name the consent prompt showed once an identity with a
/// bundle name has been seen — and that nothing else is labelled.
final class AgentIdentityLabelsTests: XCTestCase {
    private let key = "TESTTEAM00:com.example.sand-test"

    override func tearDown() {
        AgentIdentityLabels.forget(key: key)
        super.tearDown()
    }

    func testGrantAndDenialReadTheBundleNameOnceSeen() {
        XCTAssertEqual(AgentGrant(key: key, remembered: true).displayName,
                       "com.example.sand-test", "before any sighting, the key decodes")
        AgentIdentityLabels.note(AgentIdentity(
            key: key, displayName: "Grok Bot", teamId: "TESTTEAM00",
            signingId: "com.example.sand-test", verified: true,
            executablePath: "/Applications/Grok Bot.app/Contents/MacOS/Grok Bot", pid: 1))
        XCTAssertEqual(AgentGrant(key: key, remembered: true).displayName, "Grok Bot")
        XCTAssertEqual(AgentDenial(key: key, expires: nil).displayName, "Grok Bot")
    }

    func testBareSigningIdAndUnsignedPeersAreNotLabelled() {
        AgentIdentityLabels.note(AgentIdentity(
            key: key, displayName: "com.example.sand-test", teamId: "TESTTEAM00",
            signingId: "com.example.sand-test", verified: true,
            executablePath: "/usr/local/bin/sand", pid: 1))
        XCTAssertNil(AgentIdentityLabels.label(forKey: key), "the key already says it")
        let unsignedKey = "unsigned:/tmp/agent.js"
        AgentIdentityLabels.note(AgentIdentity(
            key: unsignedKey, displayName: "agent", teamId: nil,
            verified: false, executablePath: "/tmp/agent.js", pid: 1))
        XCTAssertNil(AgentIdentityLabels.label(forKey: unsignedKey))
    }
}
