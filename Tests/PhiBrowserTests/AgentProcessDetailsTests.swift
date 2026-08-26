// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import XCTest
@testable import Phi

/// Covers the evidence the consent prompt shows behind "Details": the asking
/// agent's command line and the chain of processes that launched it.
///
/// This is the part of the prompt a user checks an *unsigned* agent against —
/// its name comes from a script path or a self-chosen `argv[0]`, so the
/// command is the only thing standing behind it. What is testable from here is
/// the shape: the chain is ordered the way the alert draws it, one row is
/// marked as the agent, and an identity with no live process degrades instead
/// of disappearing.
final class AgentProcessDetailsTests: XCTestCase {

    /// The test host is a live process with a real ancestry, so it stands in
    /// for the agent: the chain must end at it, mark it, and read oldest-first
    /// — the order the alert indents rows in.
    func testDetailsForALiveProcessEndAtItAndReadOldestFirst() throws {
        let details = try XCTUnwrap(
            AgentPeerIdentity.processDetails(for: Self.identity(pid: getpid())))

        let agentRows = details.tree.filter(\.isAgent)
        XCTAssertEqual(agentRows.count, 1, "exactly one row is the agent")
        XCTAssertEqual(agentRows.first?.pid, getpid())
        XCTAssertEqual(details.tree.last?.pid, getpid(),
                       "the agent is drawn at the bottom of the tree")
        XCTAssertGreaterThan(details.tree.count, 1,
                             "a process launched by something has ancestry to show")
        XCTAssertEqual(details.tree.dropLast().last?.pid, getppid(),
                       "the row above the agent is what launched it")
    }

    /// The panel's headline field is the agent's own command, not an
    /// ancestor's — the row it belongs to is the one marked as the agent.
    func testCommandIsTheAgentsOwn() throws {
        let details = try XCTUnwrap(
            AgentPeerIdentity.processDetails(for: Self.identity(pid: getpid())))
        XCTAssertEqual(details.command, details.tree.last?.command)
        XCTAssertFalse(details.command.isEmpty)
        XCTAssertTrue(details.executablePath.hasPrefix("/"),
                      "an absolute executable path, got \(details.executablePath)")
    }

    /// Every row carries something to show. A process whose argv the kernel
    /// won't hand over falls back to its executable path rather than leaving
    /// the row blank.
    func testEveryRowNamesAProcess() throws {
        let details = try XCTUnwrap(
            AgentPeerIdentity.processDetails(for: Self.identity(pid: getpid())))
        for node in details.tree {
            XCTAssertFalse(node.name.isEmpty, "row for pid \(node.pid) has no name")
            XCTAssertFalse(node.command.isEmpty, "row for pid \(node.pid) has no command")
            XCTAssertGreaterThan(node.pid, 0)
        }
    }

    /// A pathological ancestry must not push the alert past the height it
    /// scrolls at, so the walk is bounded.
    func testTreeIsBounded() throws {
        let details = try XCTUnwrap(
            AgentPeerIdentity.processDetails(for: Self.identity(pid: getpid())))
        XCTAssertLessThanOrEqual(details.tree.count, 10)
    }

    /// Some identities have no live process behind them — the skill's own
    /// plumbing, or a peer that has since exited. The executable is still
    /// worth showing, so the disclosure degrades to it rather than vanishing.
    func testIdentityWithoutAPidFallsBackToItsExecutable() throws {
        let details = try XCTUnwrap(
            AgentPeerIdentity.processDetails(
                for: Self.identity(pid: nil, executablePath: "/usr/local/bin/some-agent")))
        XCTAssertEqual(details.command, "/usr/local/bin/some-agent")
        XCTAssertEqual(details.executablePath, "/usr/local/bin/some-agent")
        XCTAssertTrue(details.tree.isEmpty)
    }

    /// With neither a process nor a path there is nothing to disclose, and the
    /// alert hides the row instead of opening onto an empty panel.
    func testIdentityWithNothingToShowHasNoDetails() {
        XCTAssertNil(AgentPeerIdentity.processDetails(
            for: Self.identity(pid: nil, executablePath: "")))
    }

    /// A pid there is no walking (the kernel's own) yields no tree at all
    /// rather than a row of blanks, and the identity's path carries the panel.
    func testAPidThatCannotBeWalkedFallsBackToTheIdentityPath() {
        let details = AgentPeerIdentity.processDetails(for: Self.identity(pid: 0))
        XCTAssertEqual(details?.command, "/usr/bin/true")
        XCTAssertEqual(details?.tree.isEmpty, true)
    }

    /// Every row answers the same question the prompt's Identity row asks
    /// about the agent, which is the point of showing the chain: a user who
    /// doesn't recognise an unsigned script can see whether the thing that
    /// launched it is signed.
    func testEveryRowCarriesAnIdentity() throws {
        let details = try XCTUnwrap(
            AgentPeerIdentity.processDetails(for: Self.identity(pid: getpid())))
        for node in details.tree {
            let identity = try XCTUnwrap(node.identity, "no identity for pid \(node.pid)")
            XCTAssertFalse(identity.key.isEmpty)
            XCTAssertFalse(identity.detail.isEmpty)
        }
    }

    /// The agent's row keeps the identity that was resolved for it, not a bare
    /// signature check on its pid — the resolve walk names a script-run agent
    /// by its script, which a check on the interpreter's pid would not.
    func testTheAgentRowKeepsTheResolvedIdentity() throws {
        let asking = Self.identity(pid: getpid())
        let details = try XCTUnwrap(AgentPeerIdentity.processDetails(for: asking))
        XCTAssertEqual(details.tree.last?.identity, asking)
    }

    // MARK: - Answering about a launcher

    /// The root of every process on the machine is not a "who is asking", so
    /// the prompt won't let an answer be recorded against it: that is the
    /// "Apply to all agents" switch wearing a disguise.
    func testLaunchdIsNotSelectableAsASubject() throws {
        let details = try XCTUnwrap(
            AgentPeerIdentity.processDetails(for: Self.identity(pid: getpid())))
        let launchd = details.tree.first { $0.pid == 1 }
        if let launchd {
            XCTAssertFalse(launchd.isSelectableSubject)
        }
        XCTAssertTrue(try XCTUnwrap(details.tree.last).isSelectableSubject,
                      "the agent's own row is always answerable")
    }

    /// Specificity order: the agent leads, then the processes that launched
    /// it, nearest first. `AgentCDPListener` walks the list in that order, so
    /// getting it backwards would let a terminal outrank the agent under it.
    func testCandidatesRunFromTheAgentUpwards() {
        let agent = Self.identity(pid: 988, key: "unsigned:pi")
        let details = Self.details(keys: [(1, "team:launchd"), (431, "team:Terminal"),
                                          (512, "unsigned:zsh"), (988, "unsigned:pi")])
        let candidates = AgentPeerIdentity.decisionCandidates(for: agent, details: details)
        XCTAssertEqual(candidates.map(\.key),
                       ["unsigned:pi", "unsigned:zsh", "team:Terminal"],
                       "agent first, launchers nearest-first, launchd left out")
    }

    /// An agent that shares its launcher's signature is one decision, not two
    /// — and the copy that survives has to be the most specific one, since
    /// that is the tier the listener settles first.
    func testCandidatesDropDuplicateKeys() {
        let agent = Self.identity(pid: 700, key: "team:Cursor")
        let details = Self.details(keys: [(640, "team:Cursor"), (700, "team:Cursor")])
        XCTAssertEqual(
            AgentPeerIdentity.decisionCandidates(for: agent, details: details).map(\.key),
            ["team:Cursor"])
    }

    /// With no readable chain there is nothing to fall back on, and the agent
    /// is the only thing its own answer can be about.
    func testCandidatesWithoutATreeAreJustTheAgent() {
        let agent = Self.identity(pid: 988, key: "unsigned:pi")
        XCTAssertEqual(
            AgentPeerIdentity.decisionCandidates(for: agent, details: nil).map(\.key),
            ["unsigned:pi"])
    }

    /// A row with no readable executable has no identity to record an answer
    /// under, so it is skipped rather than silently answered about.
    func testCandidatesSkipRowsWithoutAnIdentity() {
        let agent = Self.identity(pid: 988, key: "unsigned:pi")
        let details = AgentProcessDetails(
            command: "pi", executablePath: "/bin/pi",
            tree: [
                AgentProcessNode(pid: 431, name: "gone", command: "gone",
                                 isAgent: false, identity: nil),
                AgentProcessNode(pid: 988, name: "pi", command: "pi",
                                 isAgent: true, identity: agent),
            ])
        XCTAssertEqual(
            AgentPeerIdentity.decisionCandidates(for: agent, details: details).map(\.key),
            ["unsigned:pi"])
    }

    /// The decision handed back to the listener knows whether the user moved
    /// it off the agent, which is what decides whose key the grant is written
    /// under.
    func testDecisionKnowsWhenItWasRetargeted() {
        let agent = Self.identity(pid: 988, key: "unsigned:pi")
        let terminal = Self.identity(pid: 431, key: "team:Terminal")
        let own = AgentAccessDecision(choice: .allow(remembered: true, allAgents: false),
                                      subject: agent)
        let moved = AgentAccessDecision(choice: .allow(remembered: true, allAgents: false),
                                        subject: terminal)
        XCTAssertFalse(own.isRetargeted(from: agent))
        XCTAssertTrue(moved.isRetargeted(from: agent))
    }

    // MARK: - The peer that could not be identified

    /// `AgentCDPListener.evaluate` refuses this identity outright, so the one
    /// thing that must never drift is which identities wear its key: exactly
    /// the stand-in, and nothing a real peer resolves to.
    func testOnlyTheStandInIsUnresolved() {
        XCTAssertTrue(AgentIdentity.unresolved.isUnresolved)
        XCTAssertEqual(AgentIdentity.unresolved.key, AgentIdentity.unresolvedKey)
        XCTAssertFalse(Self.identity(pid: getpid()).isUnresolved)
        XCTAssertFalse(Self.signed(team: "2DC432GLL2", signingId: "x").isUnresolved)
        XCTAssertFalse(AgentIdentity.unresolved.firstParty,
                       "the absence of an identity must never take the first-party pass")
    }

    /// The skill's own plumbing reaches the same refusal by the other road:
    /// the walk ran but found only our scripts, which act for whoever drives
    /// them. It must share the key — that is what makes it refused — while
    /// keeping the executable for the log line that names the delegation bug.
    func testOwnPlumbingResolvesToTheSameRefusal() {
        let plumbing = AgentIdentity.unresolvedOwnPlumbing(
            executablePath: "/opt/homebrew/bin/node")
        XCTAssertTrue(plumbing.isUnresolved)
        XCTAssertEqual(plumbing.key, AgentIdentity.unresolvedKey)
        XCTAssertEqual(plumbing.executablePath, "/opt/homebrew/bin/node")
        XCTAssertNil(plumbing.pid, "no agent behind it to echo back")
        XCTAssertFalse(plumbing.verified)
        XCTAssertFalse(plumbing.firstParty)
        XCTAssertNotEqual(plumbing.displayName, AgentIdentity.unresolved.displayName,
                          "the two roads to the refusal are told apart in the log")
    }

    /// The old behaviour minted an agent keyed to the skill DIRECTORY, so one
    /// "Always Allow" would have been inherited by every future process
    /// running anything out of it. Nothing may resolve to that key again.
    func testOwnPlumbingIsNoLongerAnAgentNamedPhiBrowser() {
        let plumbing = AgentIdentity.unresolvedOwnPlumbing(executablePath: "/bin/node")
        XCTAssertNotEqual(plumbing.key, "unsigned:phi-browser")
        XCTAssertEqual(
            AgentPeerIdentity.decisionCandidates(for: plumbing, details: nil).map(\.key),
            [AgentIdentity.unresolvedKey],
            "and it offers no launcher to be answered about instead")
    }

    /// A real peer always resolves to something, so nothing legitimate is
    /// swept into the refusal: the walk falls back through the script, the
    /// signature, and finally an unsigned path, and only an unreadable peer
    /// pid produces no identity at all.
    func testALiveProcessNeverResolvesToTheStandIn() throws {
        let resolved = try XCTUnwrap(AgentPeerIdentity.resolveClaimed(pid: getpid()))
        XCTAssertFalse(resolved.isUnresolved)
        XCTAssertFalse(resolved.key.isEmpty)
    }

    /// It carries no process and no path on purpose, which is why there is
    /// nothing to put in front of the user and why asking would be a question
    /// with no answer.
    func testTheStandInHasNothingToDisclose() {
        XCTAssertNil(AgentPeerIdentity.processDetails(for: .unresolved))
        XCTAssertNil(AgentIdentity.unresolved.pid)
        XCTAssertTrue(AgentIdentity.unresolved.executablePath.isEmpty)
    }

    /// Refusing it is the whole point, so it must not be able to arrive as the
    /// subject of an answer either — there is no launch chain to retarget onto
    /// and no row to pick.
    func testTheStandInOffersNoOtherSubject() {
        XCTAssertEqual(
            AgentPeerIdentity.decisionCandidates(for: .unresolved, details: nil).map(\.key),
            [AgentIdentity.unresolvedKey])
    }

    // MARK: - What a row says it is

    /// A team identifier is the strongest thing a signature offers, so it
    /// leads when there is one.
    func testDetailNamesTheTeamWhenThereIsOne() {
        XCTAssertEqual(
            Self.signed(team: "2DC432GLL2", signingId: "com.example.codex").detail,
            "Team 2DC432GLL2 · verified")
    }

    /// Apple's own binaries carry no team, and they are most of any launch
    /// chain. Falling back to the signing identifier is what keeps those rows
    /// from all reading "verified" and saying nothing.
    func testDetailFallsBackToTheSigningIdentifier() {
        XCTAssertEqual(
            Self.signed(team: nil, signingId: "com.apple.login").detail,
            "com.apple.login · verified")
    }

    func testDetailIsBareTrustWhenThereIsNeither() {
        XCTAssertEqual(Self.signed(team: nil, signingId: nil).detail, "verified")
    }

    func testUnsignedDetailSaysSo() {
        XCTAssertEqual(Self.identity(pid: 42).detail, "unsigned")
    }

    // MARK: - Command rendering

    /// A path with a space in it is one argument. Rendered unquoted it reads
    /// as two, which is exactly the misreading that would let a command look
    /// innocent — so the quoting is part of what the disclosure promises.
    func testArgumentsWithSpacesAreQuoted() {
        XCTAssertEqual(
            AgentPeerIdentity.commandLine(from: [
                "/usr/bin/node", "/Users/me/My Agents/cli.js", "--serve",
            ]),
            "/usr/bin/node \"/Users/me/My Agents/cli.js\" --serve")
    }

    func testQuotesInsideAnArgumentAreEscaped() {
        XCTAssertEqual(
            AgentPeerIdentity.commandLine(from: ["node", "-e", "console.log(\"hi there\")"]),
            "node -e \"console.log(\\\"hi there\\\")\"")
    }

    func testPlainArgumentsAreLeftAlone() {
        XCTAssertEqual(
            AgentPeerIdentity.commandLine(from: ["/usr/bin/node", "cli.js", "--serve"]),
            "/usr/bin/node cli.js --serve")
    }

    // MARK: - Helpers

    private static func identity(pid: pid_t?,
                                 key: String? = nil,
                                 executablePath: String = "/usr/bin/true") -> AgentIdentity {
        AgentIdentity(key: key ?? "unsigned:\(executablePath)",
                      displayName: "test-agent",
                      teamId: nil,
                      verified: false,
                      executablePath: executablePath,
                      pid: pid)
    }

    private static func signed(team: String?, signingId: String?) -> AgentIdentity {
        AgentIdentity(key: "\(team ?? "signed"):\(signingId ?? "x")",
                      displayName: signingId ?? "signed",
                      teamId: team,
                      signingId: signingId,
                      verified: true,
                      executablePath: "/usr/bin/true",
                      pid: nil)
    }

    /// A tree in the order the alert draws it — oldest ancestor first.
    private static func details(keys: [(pid_t, String)]) -> AgentProcessDetails {
        AgentProcessDetails(
            command: "command",
            executablePath: "/usr/bin/true",
            tree: keys.map { pid, key in
                AgentProcessNode(pid: pid, name: key, command: key,
                                 isAgent: pid == keys.last?.0,
                                 identity: identity(pid: pid, key: key))
            })
    }
}
