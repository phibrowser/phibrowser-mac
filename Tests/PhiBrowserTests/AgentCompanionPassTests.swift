// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import XCTest
@testable import Phi

/// Covers the companion pass — the path that admits a first-party companion
/// app's helper (Folio's today) with no consent — from the outside: the table
/// it checks against, what it refuses, and that nothing but
/// `AgentPeerIdentity` can mint a companion identity.
///
/// The accepting case needs a signed Folio.app spawning its helper and cannot
/// be staged in a unit test.
final class AgentCompanionPassTests: XCTestCase {

    // MARK: - The table

    /// The key names the app, not a build of it: a grant-free principal that
    /// stays the same across channels and updates.
    func testFolioKeyIsStable() {
        XCTAssertEqual(AgentCompanion.folio.key, "phi:companion:com.phibrowser.folio")
        XCTAssertEqual(AgentCompanion.all, [.folio])
    }

    /// The identities in docs/contracts.md, mapped by Phi's own bundle id.
    func testFolioChannelsMatchTheContract() {
        let channels = AgentCompanion.folio.channels
        XCTAssertEqual(channels.count, 2)
        XCTAssertTrue(channels.contains(AgentCompanion.Channel(
            phiBundleId: "com.phibrowser.Mac",
            appIdentifier: "com.phibrowser.folio",
            helperIdentifier: "com.phibrowser.folio.service")))
        XCTAssertTrue(channels.contains(AgentCompanion.Channel(
            phiBundleId: "com.phibrowser.canary.Mac",
            appIdentifier: "com.phibrowser.canary.folio",
            helperIdentifier: "com.phibrowser.canary.folio.service")))
    }

    #if DEBUG
    /// A locally built Phi pairs with either flavor.
    func testDebugBuildsAcceptEveryChannel() {
        XCTAssertEqual(AgentCompanion.folio.acceptedChannels, AgentCompanion.folio.channels)
    }
    #endif

    /// The requirement pins Apple's anchor, Phi's team and one identifier.
    func testRequirementTextNamesTeamAndIdentifier() {
        XCTAssertEqual(
            AgentPeerIdentity.companionRequirementText(identifier: "com.phibrowser.folio.service"),
            "anchor apple generic and certificate leaf[subject.OU] = \"87DQ3HMK5G\""
                + " and identifier \"com.phibrowser.folio.service\"")
    }

    /// Exactly the private-channel surface the contract grants.
    func testFolioAllowlistMatchesTheContract() {
        XCTAssertEqual(AgentCompanion.folio.allowedMessageTypes, [
            "agentSpace.shadow.create",
            "agentSpace.shadow.list",
            "agentSpace.shadow.openTab",
            "agentSpace.shadow.ping",
            "agentSpace.shadow.close",
            "agentSpace.listProfiles",
            "agentSpace.spaces.list",
            "agentSpace.spaces.listTabs",
            "agentSpace.spaces.openTab",
            "notification.show",
            "pageActions.register",
        ])
    }

    /// Everything else on the private channel is refused — including the
    /// chunk envelope, which would otherwise smuggle any type through.
    func testTypesOutsideTheAllowlistAreRefused() {
        for type in ["agentSpace.create", "agentSpace.spaces.create", "agentSpace.spaces.delete",
                     "agentSpace.bookmarks.list", "credentials.get", "bridge.chunk",
                     "saveForLater.fs.read", "agentSpace.shadow"] {
            XCTAssertFalse(AgentCompanion.folio.allows(messageType: type), type)
        }
        XCTAssertTrue(AgentCompanion.folio.allows(messageType: "agentSpace.shadow.create"))
    }

    // MARK: - Who can be a companion

    /// `companion` is not a parameter of the initializer every resolved peer
    /// goes through, so nothing outside the pass can mint one.
    func testResolvedIdentitiesAreNeverCompanions() {
        let identity = AgentIdentity(
            key: AgentCompanion.folio.key,
            displayName: AgentCompanion.folio.displayName,
            teamId: FileSystemUtils.teamId,
            signingId: "com.phibrowser.folio.service",
            verified: true,
            executablePath: "/Applications/Folio.app/Contents/Resources/node",
            pid: 4321)
        XCTAssertNil(identity.companion)
        XCTAssertFalse(identity.firstParty)
    }

    /// The test process is no companion's helper, whatever it is signed with.
    func testConnectionFromThisProcessIsNotRecognized() throws {
        var fds: [Int32] = [-1, -1]
        try XCTSkipIf(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) != 0, "no socketpair")
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertNil(AgentPeerIdentity.firstPartyCompanion(socketFD: fds[0]))
    }

    func testInvalidDescriptorIsNotRecognized() {
        XCTAssertNil(AgentPeerIdentity.firstPartyCompanion(socketFD: -1))
    }

    // MARK: - The bundle the helper must live in

    func testAppBundleRootOfAMainExecutable() {
        XCTAssertEqual(
            AgentPeerIdentity.appBundleRoot(forExecutablePath: "/nonexistent/Folio.app/Contents/MacOS/Folio"),
            "/nonexistent/Folio.app")
    }

    /// Only an app's main executable names its bundle; a resource inside it
    /// does not make the process an app.
    func testNonMainExecutablesHaveNoBundleRoot() {
        XCTAssertNil(AgentPeerIdentity.appBundleRoot(
            forExecutablePath: "/nonexistent/Folio.app/Contents/Resources/node"))
        XCTAssertNil(AgentPeerIdentity.appBundleRoot(forExecutablePath: "/usr/local/bin/node"))
    }
    // MARK: - How the helper was started

    private let script = "/Applications/Folio.app/Contents/Resources/folio-service/folio-service.mjs"

    func testTheAppsOwnLaunchIsAccepted() {
        XCTAssertTrue(AgentCompanion.launchIsUntampered(
            argv: ["/Applications/Folio.app/Contents/Resources/node", script],
            env: ["HOME=/Users/x", "NODE_ENV=production", "FOLIO_SOCKET_PATH=/tmp/f.sock"],
            expectedScript: script))
    }

    /// `NODE_OPTIONS=--require …` (or any other NODE_* the runtime reads) would
    /// run someone else's code as the signed helper.
    func testNodeVariablesInTheEnvironmentAreRefused() {
        for variable in ["NODE_OPTIONS=--require /tmp/x.js", "NODE_PATH=/tmp", "DYLD_INSERT_LIBRARIES=/tmp/x.dylib"] {
            XCTAssertFalse(AgentCompanion.launchIsUntampered(
                argv: ["/Applications/Folio.app/Contents/Resources/node", script],
                env: ["HOME=/Users/x", variable], expectedScript: script), variable)
        }
    }

    func testAnyOtherArgumentsAreRefused() {
        let node = "/Applications/Folio.app/Contents/Resources/node"
        for argv in [[node, "/tmp/evil.mjs"], [node, "--import", "/tmp/x.mjs", script],
                     [node, script, "--inspect"]] {
            XCTAssertFalse(AgentCompanion.launchIsUntampered(
                argv: argv, env: [], expectedScript: script), argv.joined(separator: " "))
        }
    }

    /// A native helper runs with no arguments.
    func testANativeHelpersBareLaunchIsAccepted() {
        XCTAssertTrue(AgentCompanion.launchIsUntampered(
            argv: ["/Applications/Folio.app/Contents/Helpers/folio-service"],
            env: ["HOME=/Users/x"], expectedScript: script))
    }

    /// The app itself is native code: Node's variables mean nothing to it,
    /// a dynamic-loader one does.
    func testTheAppsEnvironmentIgnoresRuntimeVariablesButNotTheLoader() {
        XCTAssertTrue(AgentCompanion.environmentIsClean(
            ["HOME=/Users/x", "NODE_OPTIONS=--inspect"], runtimeVariables: false))
        XCTAssertFalse(AgentCompanion.environmentIsClean(
            ["DYLD_INSERT_LIBRARIES=/tmp/x.dylib"], runtimeVariables: false))
    }
}
