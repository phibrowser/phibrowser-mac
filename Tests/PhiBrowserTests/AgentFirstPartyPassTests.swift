// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import XCTest
@testable import Phi

/// Covers the first-party pass — the one path that admits a CDP peer with no
/// consent and no master switches — from the outside: what it refuses, and the
/// invariant that nothing but `AgentPeerIdentity` can claim it.
///
/// The accepting case needs a live Sentinel (`runner → node → pi-agent.bundle`)
/// and cannot be staged in a unit test; what is testable is that a peer which
/// is not that shape is turned away, which is the half that matters if the
/// check ever regresses.
final class AgentFirstPartyPassTests: XCTestCase {

    /// Phi's own signed code that did not pass the first-party check is refused
    /// rather than prompted about: `AgentCDPListener.evaluate` turns away any
    /// identity carrying the unresolved key, which is what keeps the browser
    /// from asking the user to approve "Phi" to Phi Browser — and keeps an
    /// "Always Allow" from ever being keyed to a bare interpreter's signature.
    func testOwnCodeOutsideTheBrowserIsUnresolved() {
        let identity = AgentIdentity.unresolvedOwnCode(
            executablePath: "/Applications/Phi.app/Contents/Library/LoginItems/"
                + "Phi Sentinel.app/Contents/MacOS/runtime/node/bin/node")
        XCTAssertTrue(identity.isUnresolved)
        XCTAssertFalse(identity.firstParty)
        // Nothing a grant could be recorded against.
        XCTAssertEqual(identity.key, AgentIdentity.unresolvedKey)
        XCTAssertNil(identity.teamId)
        XCTAssertFalse(identity.verified)
    }

    /// `firstParty` is not a parameter of the initializer every resolved peer
    /// goes through, so no ancestry walk, delegated session, or future caller
    /// can mint an identity that skips consent.
    func testResolvedIdentitiesAreNeverFirstParty() {
        let identity = AgentIdentity(
            key: AgentPeerIdentity.firstPartyKey,
            displayName: AgentPeerIdentity.firstPartyDisplayName,
            teamId: FileSystemUtils.teamId,
            verified: true,
            executablePath: "/usr/local/bin/node",
            pid: 4321)
        // Even wearing the first-party key, name and team, an identity built
        // through the public initializer is an ordinary agent.
        XCTAssertFalse(identity.firstParty)
    }

    /// The test process is not Sentinel's bundled node running the agent
    /// bundle, so a connection from it must not be recognized — whether or not
    /// it happens to be signed with Phi's team, as a locally built test host
    /// is.
    func testConnectionFromThisProcessIsNotRecognized() throws {
        let socketPath = NSTemporaryDirectory() + "phi-fp-test-\(getpid()).sock"
        let (listener, peer) = try Self.connectedPair(at: socketPath)
        defer {
            close(peer)
            close(listener)
            unlink(socketPath)
        }
        let accepted = accept(listener, nil, nil)
        try XCTSkipIf(accepted < 0, "could not accept on the test socket")
        defer { close(accepted) }

        XCTAssertNil(AgentPeerIdentity.firstPartyAgent(socketFD: accepted))
    }

    /// A closed/invalid descriptor has no peer credentials to read, and must
    /// fail closed rather than fall through the checks.
    func testInvalidDescriptorIsNotRecognized() {
        XCTAssertNil(AgentPeerIdentity.firstPartyAgent(socketFD: -1))
    }

    /// A listening AF_UNIX socket plus a connected client, both in this
    /// process — the shape `firstPartyAgent` reads peer credentials from.
    private static func connectedPair(at path: String) throws -> (listener: Int32, peer: Int32) {
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try XCTSkipIf(listener < 0, "could not create a unix socket")

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        try XCTSkipIf(pathBytes.count > capacity, "test socket path too long")
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                pathBytes.withUnsafeBufferPointer { source in
                    destination.update(from: source.baseAddress!, count: pathBytes.count)
                }
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, length) }
        }
        try XCTSkipIf(bound != 0, "could not bind the test socket")
        try XCTSkipIf(listen(listener, 1) != 0, "could not listen on the test socket")

        let peer = socket(AF_UNIX, SOCK_STREAM, 0)
        try XCTSkipIf(peer < 0, "could not create the client socket")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(peer, $0, length) }
        }
        try XCTSkipIf(connected != 0, "could not connect the test socket")
        return (listener, peer)
    }
}
