// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// How the pill over a driven tab names the agent driving it.
///
/// The case that motivated these: the browser's own agent, reported by a
/// browser-side drive rather than by a task the app opened, arrives named
/// after its script — "phi-agent.bundle" — and `friendlyName` keeps only the
/// text after the last dot, so the pill read "bundle" over the user's tab.
final class AgentDriverBadgeTests: XCTestCase {

    // MARK: - The browser's own agent

    /// `origin` carries the answer wherever the app already knows.
    func testPhiAgentOriginWearsTheProductMark() {
        let badge = AgentDriverBadge.make(agentName: "", origin: .phiAgent)
        XCTAssertEqual(badge.label, "Phi")
        XCTAssertEqual(badge.assetName, AgentDriverBadge.phiBrandAssetName)
    }

    /// The regression: the name the ancestry walk derives for the component.
    func testScriptDerivedNameIsRecognizedInsteadOfReadingBundle() {
        let badge = AgentDriverBadge.make(agentName: "phi-agent.bundle", origin: .cdp)
        XCTAssertEqual(badge.label, "Phi", "must not fall through to \"bundle\"")
        XCTAssertEqual(badge.assetName, AgentDriverBadge.phiBrandAssetName)
    }

    /// The bare component name, and the display name the first-party pass mints.
    func testPhiAgentNameFormsAreRecognized() {
        for name in ["phi-agent", "Phi", "phi"] {
            let badge = AgentDriverBadge.make(agentName: name, origin: .cdp)
            XCTAssertEqual(badge.label, "Phi", "\(name) should read as Phi")
        }
    }

    // MARK: - Everyone else keeps their own identity

    /// pi-agent is a DIFFERENT product — an outside agent here — and must keep
    /// its own badge rather than being absorbed into Phi's.
    func testPiAgentKeepsItsOwnBadge() {
        for name in ["pi-agent.bundle", "pi-agent", "pi"] {
            let badge = AgentDriverBadge.make(agentName: name, origin: .cdp)
            XCTAssertEqual(badge.label, "Pi", "\(name) must not be labelled Phi")
            XCTAssertEqual(badge.assetName, "agent-pi")
        }
    }

    /// Matched as a whole dot-separated segment, so a name that merely
    /// contains the text cannot borrow the product's mark.
    func testLookalikeNamesDoNotBorrowTheMark() {
        for name in ["not-phi-agentx", "phi-agentx.bundle", "phi-agent-evil"] {
            let badge = AgentDriverBadge.make(agentName: name, origin: .cdp)
            XCTAssertNotEqual(badge.label, "Phi", "\(name) must not read as Phi")
            XCTAssertNotEqual(badge.assetName, AgentDriverBadge.phiBrandAssetName)
        }
    }

    /// Sibling Sentinel components are not the agent and get no Phi mark.
    func testSiblingComponentsAreNotThePhiAgent() {
        for name in ["phi-memory.bundle", "im-server.bundle", "phi-mcp-server.bundle"] {
            let badge = AgentDriverBadge.make(agentName: name, origin: .cdp)
            XCTAssertNotEqual(badge.assetName, AgentDriverBadge.phiBrandAssetName,
                              "\(name) must not wear the product mark")
        }
    }

    /// The other brands still resolve, so the new branch did not shadow them.
    func testOtherAgentBrandsStillResolve() {
        let expected: [(String, String)] = [
            ("Claude Code", "agent-claude"),
            ("codex", "agent-openai"),
            ("Cursor", "agent-cursor"),
            ("hermes", "agent-hermes"),
            ("openclaw", "agent-openclaw"),
            ("grok", "agent-grok"),
            ("antigravity", "agent-antigravity"),
            ("copilot", "agent-copilot"),
            ("opencode", "agent-opencode"),
            ("qwen", "agent-qwen"),
            ("codebuddy", "agent-codebuddy"),
        ]
        for (name, asset) in expected {
            XCTAssertEqual(AgentDriverBadge.make(agentName: name, origin: .cdp).assetName,
                           asset, "\(name) lost its badge")
        }
    }
}
