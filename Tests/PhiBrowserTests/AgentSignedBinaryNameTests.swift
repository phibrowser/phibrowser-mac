// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// How a verified bare binary — no app bundle to take a name from — is named
/// on the consent prompt.
final class AgentSignedBinaryNameTests: XCTestCase {
    /// Google's Antigravity CLI is signed just "cli"; the prompt must not
    /// read "“cli” wants to control Phi Browser".
    func testAntigravityCLIIsNamedByItsSignature() {
        XCTAssertEqual(
            AgentPeerIdentity.signedBinaryName(signingId: "cli", teamId: "EQHXZ8M8AV",
                                               path: "/Users/me/.local/bin/agy"),
            "Antigravity")
    }

    /// The same generic signing id under another team is not Antigravity; it
    /// falls back to the name the path offers.
    func testGenericSigningIdUnderAnotherTeamFallsBackToThePath() {
        XCTAssertEqual(
            AgentPeerIdentity.signedBinaryName(signingId: "cli", teamId: "OTHERTEAM0",
                                               path: "/opt/foo-tool/bin/cli"),
            "foo-tool")
        XCTAssertEqual(
            AgentPeerIdentity.signedBinaryName(signingId: "cli", teamId: nil,
                                               path: "/Users/me/.local/bin/agy"),
            "agy")
    }

    /// A signing id that already names the product is kept as-is.
    func testDescriptiveSigningIdIsKept() {
        XCTAssertEqual(
            AgentPeerIdentity.signedBinaryName(signingId: "xai-grok-pager", teamId: "5Y6N3AJ54S",
                                               path: "/Users/me/.local/bin/grok"),
            "xai-grok-pager")
        XCTAssertNil(AgentPeerIdentity.signedBinaryName(signingId: nil, teamId: nil, path: "/x/y"))
    }
}
