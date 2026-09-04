// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class ExtensionMessagingTests: XCTestCase {
    func testDriverSessionCapabilityResolvesTheSamePrincipal() {
        let identity = AgentIdentity(
            key: "test:agent-a",
            displayName: "Agent A",
            teamId: "test",
            verified: true,
            executablePath: "/test/agent-a",
            pid: ProcessInfo.processInfo.processIdentifier)
        let issued = AgentDriverSessionRegistry.shared.session(for: identity)
        let reconnected = AgentDriverSessionRegistry.shared.session(for: identity)
        let delegated = AgentDriverSessionRegistry.shared
            .session(forCapability: issued.capability)

        XCTAssertEqual(reconnected.principalId, issued.principalId)
        XCTAssertEqual(delegated?.principalId, issued.principalId)
    }

    func testDistinctProcessIdentityGetsDistinctPrincipal() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let first = AgentDriverSessionRegistry.shared.session(for: AgentIdentity(
            key: "test:agent-one",
            displayName: "Agent One",
            teamId: "test",
            verified: true,
            executablePath: "/test/agent-one",
            pid: pid))
        let second = AgentDriverSessionRegistry.shared.session(for: AgentIdentity(
            key: "test:agent-two",
            displayName: "Agent Two",
            teamId: "test",
            verified: true,
            executablePath: "/test/agent-two",
            pid: pid))

        XCTAssertNotEqual(first.principalId, second.principalId)
    }

    func testCDPTaskAllowsItsOwningPrincipal() {
        XCTAssertTrue(AgentTaskAccessPolicy.allows(
            taskOrigin: .cdp,
            taskPrincipalId: "agent-a",
            callerOrigin: .cdp,
            callerPrincipalId: "agent-a"))
    }

    func testCDPTaskRejectsAnotherApprovedPrincipal() {
        XCTAssertFalse(AgentTaskAccessPolicy.allows(
            taskOrigin: .cdp,
            taskPrincipalId: "agent-a",
            callerOrigin: .cdp,
            callerPrincipalId: "agent-b"))
    }

    func testCDPTaskRejectsUnprincipalledLegacyTunnel() {
        XCTAssertFalse(AgentTaskAccessPolicy.allows(
            taskOrigin: .cdp,
            taskPrincipalId: "agent-a",
            callerOrigin: .cdp,
            callerPrincipalId: nil))
    }

    func testOriginsRemainIsolated() {
        XCTAssertFalse(AgentTaskAccessPolicy.allows(
            taskOrigin: .phiAgent,
            taskPrincipalId: nil,
            callerOrigin: .cdp,
            callerPrincipalId: "agent-a"))
        XCTAssertFalse(AgentTaskAccessPolicy.allows(
            taskOrigin: .cdp,
            taskPrincipalId: "agent-a",
            callerOrigin: .phiAgent,
            callerPrincipalId: nil))
    }

    func testPhiAgentTaskStillUsesBackendOriginBoundary() {
        XCTAssertTrue(AgentTaskAccessPolicy.allows(
            taskOrigin: .phiAgent,
            taskPrincipalId: nil,
            callerOrigin: .phiAgent,
            callerPrincipalId: nil))
    }

    // MARK: - Capability header parsing

    private static let sampleCapability = String(repeating: "a", count: 43)

    private func head(_ headers: [String], body: String? = nil) -> String {
        var lines = ["GET /phi-agent HTTP/1.1", "Host: localhost"] + headers
        lines.append("")
        lines.append(body ?? "")
        return lines.joined(separator: "\r\n")
    }

    func testCapabilityClaimParsesValidHeader() {
        let value = Self.sampleCapability
        XCTAssertEqual(
            AgentCDPListener.capabilityClaim(
                inRequestHead: head(["X-Phi-Agent-Capability: \(value)"])),
            .valid(value))
        // Header names are case-insensitive.
        XCTAssertEqual(
            AgentCDPListener.capabilityClaim(
                inRequestHead: head(["x-phi-agent-capability: \(value)"])),
            .valid(value))
    }

    func testCapabilityClaimAbsentWhenNoHeader() {
        XCTAssertEqual(
            AgentCDPListener.capabilityClaim(
                inRequestHead: head(["X-Phi-Agent-Pid: 123"])),
            .absent)
    }

    func testCapabilityClaimRejectsMalformedValues() {
        // Too short, too long, and bad characters are all .invalid — a
        // presented capability never silently degrades to peer identity.
        XCTAssertEqual(
            AgentCDPListener.capabilityClaim(
                inRequestHead: head(["X-Phi-Agent-Capability: short"])),
            .invalid)
        XCTAssertEqual(
            AgentCDPListener.capabilityClaim(
                inRequestHead: head(["X-Phi-Agent-Capability: \(String(repeating: "a", count: 129))"])),
            .invalid)
        XCTAssertEqual(
            AgentCDPListener.capabilityClaim(
                inRequestHead: head(["X-Phi-Agent-Capability: \(String(repeating: "a", count: 40))$$$"])),
            .invalid)
    }

    func testCapabilityClaimRejectsDuplicateHeaders() {
        XCTAssertEqual(
            AgentCDPListener.capabilityClaim(inRequestHead: head([
                "X-Phi-Agent-Capability: \(Self.sampleCapability)",
                "X-Phi-Agent-Capability: \(String(repeating: "b", count: 43))",
            ])),
            .invalid)
    }

    func testCapabilityClaimIgnoresBodyBytes() {
        // A matching line in peeked BODY bytes is not a claim: scanning stops
        // at the head/body boundary.
        XCTAssertEqual(
            AgentCDPListener.capabilityClaim(inRequestHead: head(
                [], body: "X-Phi-Agent-Capability: \(Self.sampleCapability)")),
            .absent)
    }

    // MARK: - Restart adoption

    private func identity(key: String, pid: pid_t?) -> AgentIdentity {
        AgentIdentity(key: key, displayName: key, teamId: "test",
                      verified: true, executablePath: "/test/\(key)", pid: pid)
    }

    func testDeadOwnerSameIdentityIsAdoptable() {
        // A nil pid never resolves a process anchor, so the owner counts as
        // gone; the caller is the same identity, freshly launched.
        let owner = AgentDriverSessionRegistry.shared
            .session(for: identity(key: "test:adopt-dead", pid: nil))
        let caller = AgentDriverSessionRegistry.shared
            .session(for: identity(key: "test:adopt-dead",
                                   pid: ProcessInfo.processInfo.processIdentifier))
        XCTAssertTrue(AgentDriverSessionRegistry.shared.canAdopt(
            taskPrincipalId: owner.principalId,
            callerPrincipalId: caller.principalId))
    }

    func testLiveOwnerIsNeverAdoptable() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let owner = AgentDriverSessionRegistry.shared
            .session(for: identity(key: "test:adopt-live", pid: pid))
        let caller = AgentDriverSessionRegistry.shared
            .session(for: identity(key: "test:adopt-live", pid: nil))
        XCTAssertFalse(AgentDriverSessionRegistry.shared.canAdopt(
            taskPrincipalId: owner.principalId,
            callerPrincipalId: caller.principalId))
    }

    func testDifferentIdentityCannotAdoptDeadOwnersTask() {
        let owner = AgentDriverSessionRegistry.shared
            .session(for: identity(key: "test:adopt-owner", pid: nil))
        let caller = AgentDriverSessionRegistry.shared
            .session(for: identity(key: "test:adopt-other",
                                   pid: ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(AgentDriverSessionRegistry.shared.canAdopt(
            taskPrincipalId: owner.principalId,
            callerPrincipalId: caller.principalId))
    }

    func testUnknownIdentityIsNeverAdoptable() {
        // "unknown" is the unresolvable-peer fallback — treating two unknown
        // peers as the same agent would make them interchangeable.
        let owner = AgentDriverSessionRegistry.shared
            .session(for: AgentIdentity(key: "unknown", displayName: "Unknown process",
                                        teamId: nil, verified: false,
                                        executablePath: "", pid: nil))
        let caller = AgentDriverSessionRegistry.shared
            .session(for: AgentIdentity(key: "unknown", displayName: "Unknown process",
                                        teamId: nil, verified: false,
                                        executablePath: "", pid: nil))
        XCTAssertFalse(AgentDriverSessionRegistry.shared.canAdopt(
            taskPrincipalId: owner.principalId,
            callerPrincipalId: caller.principalId))
    }

    func testPrincipalCannotAdoptItself() {
        let session = AgentDriverSessionRegistry.shared
            .session(for: identity(key: "test:adopt-self", pid: nil))
        XCTAssertFalse(AgentDriverSessionRegistry.shared.canAdopt(
            taskPrincipalId: session.principalId,
            callerPrincipalId: session.principalId))
    }

    // MARK: - Session pruning

    private var afterGrace: Date {
        Date().addingTimeInterval(AgentDriverSessionRegistry.pruneGraceSeconds + 60)
    }

    func testPruneDropsDeadUnretainedSessions() {
        let dead = AgentDriverSessionRegistry.shared
            .session(for: identity(key: "test:prune-dead", pid: nil))
        AgentDriverSessionRegistry.shared.prune(retaining: [], now: afterGrace)
        XCTAssertNil(AgentDriverSessionRegistry.shared
            .session(forCapability: dead.capability))
    }

    func testPruneKeepsRetainedSessions() {
        // Retention (a live task or connection) outlives the owner process —
        // the mirror daemon's deferred completion depends on this.
        let dead = AgentDriverSessionRegistry.shared
            .session(for: identity(key: "test:prune-retained", pid: nil))
        AgentDriverSessionRegistry.shared.prune(retaining: [dead.principalId],
                                                now: afterGrace)
        XCTAssertEqual(AgentDriverSessionRegistry.shared
            .session(forCapability: dead.capability)?.principalId,
            dead.principalId)
    }

    func testPruneKeepsLiveOwnersAndYoungSessions() {
        let live = AgentDriverSessionRegistry.shared
            .session(for: identity(key: "test:prune-live",
                                   pid: ProcessInfo.processInfo.processIdentifier))
        AgentDriverSessionRegistry.shared.prune(retaining: [], now: afterGrace)
        XCTAssertNotNil(AgentDriverSessionRegistry.shared
            .session(forCapability: live.capability))

        // Within the issuance grace even a dead-looking session survives.
        let young = AgentDriverSessionRegistry.shared
            .session(for: identity(key: "test:prune-young", pid: nil))
        AgentDriverSessionRegistry.shared.prune(retaining: [])
        XCTAssertNotNil(AgentDriverSessionRegistry.shared
            .session(forCapability: young.capability))
    }

    func testRegisteredHandlerReceivesContextAndReturnsResponse() {
        let router = ExtensionMessageRouter()
        var receivedContext: ExtensionMessageContext?
        router.register(type: "test.echo") { context in
            receivedContext = context
            return #"{"ok":true}"#
        }

        let response = router.handle(
            type: "test.echo",
            payload: #"{"message":"hello"}"#,
            requestId: "request-123",
            senderId: "extension-456",
            agentName: "test-agent"
        )

        XCTAssertEqual(response, #"{"ok":true}"#)
        XCTAssertEqual(receivedContext?.type, "test.echo")
        XCTAssertEqual(receivedContext?.payload, #"{"message":"hello"}"#)
        XCTAssertEqual(receivedContext?.requestId, "request-123")
        XCTAssertEqual(receivedContext?.senderId, "extension-456")
        XCTAssertEqual(receivedContext?.agentName, "test-agent")
    }

    func testSeparatelyRegisteredTypesDispatchIndependently() {
        let router = ExtensionMessageRouter()
        var handledTypes: [String] = []
        router.register(type: "test.first") { context in
            handledTypes.append(context.type)
            return "first-response"
        }
        router.register(type: "test.second") { context in
            handledTypes.append(context.type)
            return "second-response"
        }

        let firstResponse = router.handle(
            type: "test.first",
            payload: "",
            requestId: "request-first"
        )
        let secondResponse = router.handle(
            type: "test.second",
            payload: "",
            requestId: "request-second"
        )

        XCTAssertEqual(firstResponse, "first-response")
        XCTAssertEqual(secondResponse, "second-response")
        XCTAssertEqual(handledTypes, ["test.first", "test.second"])
    }

    @MainActor
    func testAIOutputStateMessageIsAcknowledgedSynchronously() {
        let router = ExtensionMessageRouter()

        let response = router.handle(
            type: "sidecar.aiOutputState",
            payload: #"{"tabId":42,"windowId":7,"active":true,"phase":"submitted","seq":1}"#,
            requestId: "ai-output-state",
            senderId: SidecarAIOutputStateStore.extensionId
        )

        XCTAssertEqual(response, "{}")
        SidecarAIOutputStateStore.shared.removeAll()
    }
}
