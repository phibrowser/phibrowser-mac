// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import Foundation
import Security

/// Who is on the other end of an agent CDP connection. Resolved from the
/// connected socket's peer pid: we walk the process ancestry to the
/// "responsible" process (the agent, not the `node`/shell that launched it),
/// verify its code signature, and reduce it to a stable identity the user can
/// grant once and have remembered.
///
/// This is an *identification* aid for the consent prompt, not a security
/// boundary — the boundary is the same-uid check plus the user's decision.
/// A same-user process can always launch a genuinely-signed agent to inherit
/// its grant; the prompt and the revocable grants list are the mitigation.
struct AgentIdentity: Equatable {
    /// Stable key for remembering a grant: "teamId:signingId" when the
    /// responsible process is validly signed, else "unsigned:<path>".
    let key: String
    /// Human-readable name for the consent prompt (signing identifier or
    /// process name).
    let displayName: String
    /// Team identifier from the code signature, nil when unsigned.
    let teamId: String?
    /// Signing identifier from the code signature ("com.apple.login"), nil
    /// when unsigned. Apple's own platform binaries carry no team identifier,
    /// so on a launch chain full of them this is the only thing that says what
    /// a verified process actually IS — which is the whole reason the chain is
    /// on screen.
    let signingId: String?
    /// True when the responsible process carries a valid code signature.
    let verified: Bool
    /// Absolute path of the responsible process's executable.
    let executablePath: String
    /// Pid of the responsible/branded agent process, nil when the identity is
    /// a fallback with no real agent behind it. Echoed to `/phi-agent` clients
    /// (see AgentDirectConnection) so a SANDBOXED skill round — which cannot
    /// walk its own ancestry (Codex's seatbelt denies the sysctls `ps` needs)
    /// — still learns the agent pid to record for its detached daemon and
    /// watchers to claim.
    let pid: pid_t?
    /// True only for the browser's own agent runtime, recognized by
    /// `AgentPeerIdentity.firstPartyAgent` rather than resolved from an
    /// arbitrary peer's ancestry. It is the one identity that connects without
    /// the user's consent (see `AgentCDPListener.evaluate`).
    let firstParty: Bool

    /// The initializer every resolved peer goes through. `firstParty` is
    /// deliberately not a parameter: being the browser's own runtime is
    /// something this file establishes from the connection, never something a
    /// caller can assert.
    init(key: String, displayName: String, teamId: String?,
         signingId: String? = nil, verified: Bool,
         executablePath: String, pid: pid_t?) {
        self.init(key: key, displayName: displayName, teamId: teamId,
                  signingId: signingId, verified: verified,
                  executablePath: executablePath, pid: pid, firstParty: false)
    }

    fileprivate init(key: String, displayName: String, teamId: String?,
                     signingId: String?, verified: Bool,
                     executablePath: String, pid: pid_t?, firstParty: Bool) {
        self.key = key
        self.displayName = displayName
        self.teamId = teamId
        self.signingId = signingId
        self.verified = verified
        self.executablePath = executablePath
        self.pid = pid
        self.firstParty = firstParty
    }

    /// Key of the identity below. Its own constant because the rule attached
    /// to it — never admitted, never remembered, never interchangeable with
    /// another peer wearing it — is enforced in more than one file, and a
    /// literal "unknown" spread across them is a rule waiting to be missed.
    static let unresolvedKey = "unknown"

    /// The stand-in for a peer whose process could not be resolved at all:
    /// the socket would not name a pid, so there is no ancestry to walk, no
    /// signature to check, and nothing to tell the user.
    ///
    /// It is not an identity but the absence of one, and every unidentifiable
    /// peer that ever connects wears exactly this key. That is what makes it
    /// unanswerable: an "Always Allow" against it would not approve a program,
    /// it would approve the *condition* of being unidentifiable, permanently
    /// and for everyone. `AgentCDPListener.evaluate` refuses it outright
    /// instead of asking (see there for why that is safe).
    static let unresolved = AgentIdentity(
        key: unresolvedKey, displayName: "Unknown process", teamId: nil,
        verified: false, executablePath: "", pid: nil)

    /// The same absence reached a second way: the ancestry walk ran, but
    /// everything it found was the phi-browser skill's own plumbing — its
    /// heredoc runner, its CLI, its detached mirror daemon — with no agent
    /// above them to name.
    ///
    /// That is not an agent called "phi-browser", which is what this used to
    /// resolve to and what the prompt then asked the user about. The skill's
    /// scripts act for whoever drives them; when the walk can see nothing but
    /// them, what it has established is that it could not find the driver.
    /// Saying so is both truer and safer: the old name was keyed to the skill
    /// directory, so one "Always Allow" would have been inherited by every
    /// future process running anything out of it.
    ///
    /// A helper in this position has a way in that does not depend on the
    /// walk — the capability its spawning round delegates joins the agent's
    /// session directly, and a connection carrying one is evaluated as that
    /// session and never arrives here. Reaching this point means none was
    /// presented. `executablePath` is kept for the log line that says so.
    static func unresolvedOwnPlumbing(executablePath: String) -> AgentIdentity {
        AgentIdentity(key: unresolvedKey,
                      displayName: "the phi-browser skill's own plumbing",
                      teamId: nil, verified: false,
                      executablePath: executablePath, pid: nil)
    }

    /// Whether this is that stand-in, in either of its forms.
    var isUnresolved: Bool { key == Self.unresolvedKey }

    /// Secondary line for the prompt, e.g. "Team 87DQ3HMK5G · verified".
    ///
    /// A verified process always names what it is signed as: its team when it
    /// has one, and otherwise its signing identifier — Apple's own binaries
    /// have no team, and a launch chain of bare "verified" rows says nothing
    /// the user can act on.
    var detail: String {
        let trust = verified
            ? NSLocalizedString("agentControl.connectionApproval.identity.verifiedStatus", value: "verified", comment: "CDP consent - signature verified")
            : NSLocalizedString("agentControl.connectionApproval.identity.unsignedStatus", value: "unsigned", comment: "CDP consent - no valid signature")
        if let teamId, !teamId.isEmpty {
            return String(
                format: NSLocalizedString("agentControl.connectionApproval.identity.teamSummary", value: "Team %@ · %@",
                                          comment: "CDP consent - team and trust"),
                teamId, trust)
        }
        if let signingId, !signingId.isEmpty {
            return String(
                format: NSLocalizedString("agentControl.connectionApproval.identity.signingIdSummary", value: "%@ · %@",
                                          comment: "CDP consent - signing identifier and trust, for a signature that carries no team identifier (Apple's own binaries); first %@ is the signing identifier, second is the trust word"),
                signingId, trust)
        }
        return trust
    }
}

/// One entry in the Developer settings "Allowed agents" list: an identity the
/// user has granted CDP access, either persisted ("Always Allow") or for this
/// session only ("Allow Once").
///
/// Unlike `AgentDenial` this never carries the "all agents" scope: a blanket
/// grant is not one entry among many but the switch above the whole list
/// (`AgentCDPListener.allAgentsGranted`), because while it stands the entries
/// below decide nothing.
struct AgentGrant: Identifiable {
    let key: String
    let remembered: Bool
    var id: String { key }

    /// Signing identifier, or a friendly name derived from the path for an
    /// unsigned/script peer (e.g. a `node` CLI agent named by the script it
    /// runs, not the interpreter binary).
    var displayName: String {
        if key.hasPrefix("unsigned:") {
            let path = String(key.dropFirst("unsigned:".count))
            return AgentPeerIdentity.deriveAgentName(fromPath: path)
        }
        if let range = key.range(of: ":") {
            return String(key[range.upperBound...])
        }
        return key
    }

    /// Team identifier when the key encodes one ("teamId:signingId").
    var teamId: String? {
        guard !key.hasPrefix("unsigned:"), !key.hasPrefix("signed:"),
              let range = key.range(of: ":") else { return nil }
        return String(key[..<range.lowerBound])
    }
}

/// A standing refusal recorded from the consent prompt's deny options: the
/// peer is turned away with no prompt at all until `expires` — or forever, for
/// "Never ask again". `key` is an `AgentIdentity.key`, or nil for the
/// "all agents" scope, which turns away every agent including ones never seen.
///
/// Unlike `CredentialGrant`, timed entries are persisted rather than dropped at
/// relaunch. The asymmetry is deliberate: forgetting a *grant* fails safe (the
/// agent must ask again), while forgetting a *denial* fails open (the agent the
/// user just silenced starts prompting again after an unrelated restart).
struct AgentDenial: Codable, Equatable, Identifiable {
    /// nil = every agent.
    let key: String?
    /// nil = never expires.
    let expires: Date?

    var id: String {
        (key ?? "*") + "@" + (expires.map { String($0.timeIntervalSince1970) } ?? "never")
    }

    var appliesToAllAgents: Bool { key == nil }
    var isPermanent: Bool { expires == nil }
    var isExpired: Bool { (expires ?? .distantFuture) <= Date() }

    /// Whether this entry turns away the agent identified by `identityKey`.
    func covers(_ identityKey: String) -> Bool { key == nil || key == identityKey }

    /// Whether this entry makes `other` redundant — at least as broad in scope
    /// and standing at least as long.
    func supersedes(_ other: AgentDenial) -> Bool {
        (key == nil || key == other.key)
            && (expires ?? .distantFuture) >= (other.expires ?? .distantFuture)
    }

    /// Display name for the Developer settings "Blocked agents" list, reusing
    /// `AgentGrant`'s key decoding so a blocked agent reads the same as an
    /// allowed one.
    var displayName: String {
        guard let key else {
            return NSLocalizedString("settings.developer.agentControl.blockedAgents.allAgentsName", value: "All agents", comment: "Developer settings - name of the blocked-agents entry that covers every agent")
        }
        return AgentGrant(key: key, remembered: false).displayName
    }
}

/// One process in the chain that led to an agent connecting, as shown behind
/// the consent prompt's "Details" disclosure.
///
/// The prompt names an agent; this is the evidence for that name. It matters
/// most when the agent is unsigned, where the name is derived from a script
/// path or an `argv[0]` the process chose for itself and there is no signature
/// standing behind it — the command and the chain above it are then the only
/// things the user can actually check.
struct AgentProcessNode: Equatable, Identifiable {
    let pid: pid_t
    /// Short name for the row, e.g. "node" or the brand in `argv[0]`.
    let name: String
    /// Full command line, or the executable path when argv is unreadable.
    let command: String
    /// True for the one process the prompt is naming as the agent.
    let isAgent: Bool
    /// Who this process is by its code signature — the same question the
    /// prompt's Identity row answers about the agent, asked of the thing that
    /// launched it. It is also what a decision retargeted onto this row would
    /// be recorded under, so a user who does not recognise an unsigned script
    /// can answer about the signed app above it instead. Nil when the process
    /// has no readable executable to check.
    let identity: AgentIdentity?

    var id: pid_t { pid }

    /// Whether the prompt will let the user answer about this row. The root of
    /// every process on the machine is not a meaningful "who is asking":
    /// allowing launchd would admit anything the user ever runs, which is what
    /// the alert's "Apply to all agents" switch says out loud and Settings can
    /// take back — reaching the same power through an innocuous-looking row is
    /// the trap this closes.
    var isSelectableSubject: Bool { identity != nil && pid > 1 }
}

/// What the consent prompt shows behind "Details": the asking agent's own
/// command line and the ancestry that launched it.
struct AgentProcessDetails: Equatable {
    /// The agent's command line, or its executable path as a fallback.
    let command: String
    let executablePath: String
    /// Oldest ancestor first, the agent process last, so the list reads as a
    /// tree from the top down. Empty when the ancestry can't be read.
    let tree: [AgentProcessNode]
}

enum AgentPeerIdentity {
    /// Tools that merely *carry* an agent's work — interpreters, shells,
    /// process wrappers, and the transports an agent reaches the socket
    /// through. Never the identity we present: the walk skips past these to
    /// the real launcher. Membership is checked through `canonicalToolName`,
    /// so versioned binaries ("python3.11") match their base entry.
    ///
    /// `curl` earns its place the hard way — being Apple-signed, it looked
    /// like a perfectly good identity and every hand-run or scripted request
    /// resolved to "com.apple.curl", naming the pipe instead of whoever was
    /// on the other end of it.
    private static let passthroughNames: Set<String> = [
        "node", "deno", "bun", "npm", "npx", "pnpm", "yarn", "corepack",
        "tsx", "ts-node", "uv", "uvx",
        "python", "ruby", "perl", "php",
        "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh",
        "env", "login", "sudo", "xargs", "timeout", "curl",
    ]

    /// The subset of `passthroughNames` that run a SCRIPT as their first real
    /// argument. When the responsible process is one of these (a bare CLI agent
    /// with no signed-app ancestor), we name it by the script it runs rather
    /// than by the interpreter's meaningless ad-hoc signing id ("node-<cdhash>").
    private static let scriptInterpreters: Set<String> = [
        "node", "deno", "bun", "tsx", "ts-node",
        "python", "ruby", "perl", "php", "uv", "uvx",
    ]

    /// Tool names matched with any trailing version stripped: a venv's
    /// `python3` is a symlink whose process reads back (proc_pidpath) as the
    /// real versioned binary — a uv-managed python is `python3.11` — and an
    /// exact-name lookup then mistakes the interpreter for the agent itself.
    /// "python3.11" → "python", "node18" → "node".
    private static func canonicalToolName(_ name: String) -> String {
        var stem = Substring(name.lowercased())
        while let last = stem.last, last.isNumber || last == "." {
            stem = stem.dropLast()
        }
        return stem.isEmpty ? name.lowercased() : String(stem)
    }

    private static func isPassthroughName(_ name: String) -> Bool {
        let canonical = canonicalToolName(name)
        if passthroughNames.contains(canonical) { return true }
        // Homebrew's coreutils installs the GNU builds under a "g" prefix
        // (gtimeout, gxargs, genv), which no more identifies an agent than
        // the BSD tool it shadows. Only a name whose de-prefixed form is
        // ALREADY passthrough matches, so "git" ("it") and "go" ("o") — and
        // any other agent that happens to start with g — are untouched.
        guard canonical.hasPrefix("g") else { return false }
        return passthroughNames.contains(String(canonical.dropFirst()))
    }

    private static func isScriptInterpreterName(_ name: String) -> Bool {
        scriptInterpreters.contains(canonicalToolName(name))
    }

    /// Resolves the identity of the process connected on `socketFD`, or nil
    /// when the peer pid can't be read. Runs synchronous filesystem and
    /// Security calls — call it off the main thread.
    static func resolve(socketFD: Int32) -> AgentIdentity? {
        guard let peerPID = peerProcessID(socketFD: socketFD) else { return nil }
        return resolve(pid: peerPID)
    }

    /// Identity of a process the connecting client CLAIMS to act for. A
    /// client whose ancestry no longer reaches its driving agent — the
    /// skill's detached mirror daemon, a hand-back watcher orphaned by a
    /// backgrounding shell — names the agent's pid in the request instead
    /// (an `agentPid` query or `X-Phi-Agent-Pid` header, on any route).
    /// Honored only for a live process of the same user; a claim is an
    /// identification aid exactly like argv[0] branding (see the header
    /// note), not a security boundary.
    static func resolveClaimed(pid: pid_t) -> AgentIdentity? {
        guard pid > 0, processUID(pid) == getuid() else { return nil }
        return resolve(pid: pid, claimed: true)
    }

    // MARK: - First-party pass

    /// The browser's own agent runtime, which Sentinel starts as a component
    /// of the product rather than as an outside agent the user invited in:
    ///
    ///     Phi Sentinel.app → runner → node → phi-agent.bundle.js
    ///
    /// It is recognized instead of prompted for, and `AgentCDPListener` admits
    /// it without consent and without the two master switches — a built-in
    /// feature must not ask the user to turn on Developer mode to work. That
    /// makes this the one identity where the code signature IS the boundary
    /// rather than an aid to naming the agent, so all three of these must hold
    /// and the same-uid gate still applies before any of them:
    ///
    ///   1. the connecting process is Phi-signed — Sentinel's own bundled node,
    ///      pinned to this socket by its peer audit token;
    ///   2. its first argument is the agent bundle, so a signed interpreter
    ///      cannot be pointed at some other script;
    ///   3. its parent is Phi-signed too — Sentinel's `runner`.
    ///
    /// (3) is what carries the check: (1) and (2) alone are satisfied by
    /// anyone who runs Sentinel's node — it is readable by every process of
    /// this user — against a file they named `phi-agent.bundle.js`.
    ///
    /// Returns nil for every other connection, which then resolves normally
    /// and faces the consent prompt.
    static func firstPartyAgent(socketFD: Int32) -> AgentIdentity? {
        guard let auditToken = peerAuditToken(socketFD: socketFD) else { return nil }
        // The audit token's sixth word is the pid. `audit_token_to_pid` lives
        // in libbsm, which has no module map to import from Swift.
        let peerPID = pid_t(bitPattern: auditToken.val.5)
        guard peerPID > 0 else { return nil }

        let tokenData = withUnsafeBytes(of: auditToken) { Data($0) } as CFData
        guard isFirstPartyCode(guestAttributes: [kSecGuestAttributeAudit: tokenData],
                               pid: peerPID) else {
            return nil
        }
        guard let interpreter = executablePath(peerPID),
              isScriptInterpreterName((interpreter as NSString).lastPathComponent),
              let argv = processArgv(peerPID), argv.count >= 2 else {
            return nil
        }
        // argv[1] specifically, not "the first argument that names a file":
        // node options precede the script, and one of them is `--require`.
        // Anything else — including a first-party bundle behind an option —
        // fails the pass rather than being reasoned about.
        let script = argv[1]
        guard firstPartyScriptNames.contains((script as NSString).lastPathComponent) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: script) else { return nil }
        guard let parent = parentPID(peerPID), parent > 1,
              isFirstPartyCode(guestAttributes: [kSecGuestAttributePid: parent],
                               pid: parent) else {
            AppLogWarn("[AgentCDP] \((script as NSString).lastPathComponent) ran from a "
                       + "Phi-signed interpreter but not from a Phi-signed parent; "
                       + "treating it as an ordinary agent")
            return nil
        }

        return AgentIdentity(
            key: firstPartyKey,
            displayName: firstPartyDisplayName,
            teamId: FileSystemUtils.teamId,
            signingId: FileSystemUtils.bundleId,
            verified: true,
            executablePath: interpreter,
            pid: peerPID,
            firstParty: true)
    }

    /// Script bundles that ARE the browser's agent runtime. Matched on file
    /// name alone: Sentinel downloads the bundle to a versioned, user-writable
    /// path under Application Support, so neither its location nor its
    /// contents prove anything — the ancestry checks above are what do.
    private static let firstPartyScriptNames: Set<String> = ["phi-agent.bundle.js"]

    /// Identity key for the pass. Deliberately a constant: the key a normal
    /// resolve would produce embeds the bundle's version and the signed-in
    /// account (".../phi-agent/2026.8.21.1619/arm64/phi-agent.bundle.js"), so
    /// it would name a different agent after every component update.
    static let firstPartyKey = "phi:phi-agent"

    /// Shown wherever a driving agent is named — the Space switcher, the
    /// transcript — so the browser's own agent reads as itself rather than as
    /// the "phi-agent.bundle" script an ancestry walk would call it.
    static let firstPartyDisplayName = "Phi Agent"

    /// Peer credentials as an audit token, which names the process on the
    /// other end of `socketFD` unambiguously. `LOCAL_PEERPID` gives only a pid,
    /// and a pid can be recycled onto an unrelated process between reading it
    /// and checking its signature.
    private static func peerAuditToken(socketFD: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        let rc = withUnsafeMutablePointer(to: &token) {
            getsockopt(socketFD, SOL_LOCAL, LOCAL_PEERTOKEN, $0, &len)
        }
        guard rc == 0, len == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
        return token
    }

    /// Whether a process is Phi's own code. `guestAttributes` locates the
    /// running process (an audit token where we have one, else a pid); `pid`
    /// is only for the fallback below.
    private static func isFirstPartyCode(guestAttributes: [CFString: Any],
                                         pid: pid_t) -> Bool {
        if satisfiesFirstPartyRequirement(guestAttributes: guestAttributes) { return true }
        // The running process can be unreadable because its executable was
        // replaced on disk since it launched — routine during development,
        // where a rebuild unlinks the binary that a long-lived Sentinel is
        // still running from and the dynamic query then fails with ENOENT.
        // Fall back to the exec path the kernel recorded, which the process
        // itself cannot rewrite: it still takes a Phi-signed binary to have
        // been launched from one. What lapses is only the assurance that the
        // copy on disk is the code the process is running.
        guard let path = recordedExecutablePath(pid) else { return false }
        var staticCode: SecStaticCode?
        guard let requirement = firstPartyRequirement,
              SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL,
                                          [], &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }
        return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
    }

    private static func satisfiesFirstPartyRequirement(guestAttributes: [CFString: Any]) -> Bool {
        guard let requirement = firstPartyRequirement else { return false }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(
                nil, guestAttributes as CFDictionary, [], &code) == errSecSuccess,
              let code else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// Valid signature, Apple-issued chain, Phi's team. `anchor apple generic`
    /// is what makes the team identifier mean anything: without it a
    /// self-signed certificate carrying "87DQ3HMK5G" in its OU would satisfy
    /// the check.
    private static let firstPartyRequirement: SecRequirement? = {
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(FileSystemUtils.teamId)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess else {
            AppLogError("[AgentCDP] could not compile the first-party code requirement")
            return nil
        }
        return requirement
    }()

    /// Identity of an arbitrary same-user process — the socket peer, or a
    /// pid the peer claims to act for (`claimed`).
    private static func resolve(pid peerPID: pid_t, claimed: Bool = false) -> AgentIdentity? {
        let responsible = responsiblePID(startingAt: peerPID)
        let path = executablePath(responsible) ?? "pid-\(responsible)"
        let exeName = (path as NSString).lastPathComponent
        // A script-run agent is named by the interpreter that runs it, found
        // between the peer and the responsible process: a bare interpreter
        // agent (responsible falls back to the peer, whose ad-hoc id like
        // "node-<cdhash>" is meaningless), or a script CLI under a terminal
        // (hermes is `python3.11 …/venv/bin/hermes` under Terminal.app —
        // naming the terminal would tell the user nothing). The walk stops
        // below a real responsible process, so a signed agent app above the
        // peer is never overridden by its own helper scripts.
        let responsibleIsInterpreter = isScriptInterpreterName(exeName)
        if let scripted = scriptIdentity(
                startingAt: peerPID,
                stopBefore: responsibleIsInterpreter ? nil : responsible) {
            return scripted
        }
        // Pi running under a launcher (herdr, tmux, a supervisor daemon) the
        // responsible-process walk stops on, masking pi behind the launcher's
        // identity. Recover pi SPECIFICALLY from its self-brand, so this can
        // only ever yield pi — never override another agent's signed grant.
        if let pi = piIdentity(startingAt: peerPID, claimed: claimed) {
            return pi
        }
        return signingIdentity(pid: responsible, executablePath: path)
    }

    /// Pi identity when this connection belongs to a pi coding-agent session
    /// masked by a non-passthrough launcher, else nil. Pi self-identifies two
    /// ways, and which is visible depends on the process being resolved:
    ///   • It exports PI_CODING_AGENT=true, then spawns its tools — so every
    ///     child that connects (the mirror heredoc, the tool shell, the
    ///     detached daemon) inherits the marker at exec. But pi's OWN environ
    ///     snapshot lacks it: pi sets it at runtime, after exec, and
    ///     KERN_PROCARGS2 reflects only the exec-time environment. So the
    ///     marker proves a pi session from the CONNECTING PEER, never from pi.
    ///   • It rewrites argv[0] to its app name ("pi"), visible on the pi
    ///     process itself — how we locate pi in the ancestry, and how we accept
    ///     a detached daemon's claim of pi's pid (`claimed`, its own environ
    ///     carrying the marker but out of reach behind the pid).
    /// Requiring the "pi" brand on the located process keeps an unrelated
    /// process that merely inherited the marker from being taken for pi.
    private static func piIdentity(startingAt peerPID: pid_t,
                                   claimed: Bool) -> AgentIdentity? {
        guard let piPid = piBrandedAncestor(startingAt: peerPID),
              environHasPiMarker(peerPID) || (claimed && piPid == peerPID) else {
            return nil
        }
        return unsignedIdentity(name: "pi", path: "pi",
                                exe: executablePath(piPid) ?? "pi", pid: piPid)
    }

    /// The nearest ancestor (from the peer up) that is a pi process — a script
    /// interpreter branded argv[0]=="pi" — or nil.
    private static func piBrandedAncestor(startingAt peerPID: pid_t) -> pid_t? {
        var pid = peerPID
        var guardCount = 0
        while pid > 1 && guardCount < 32 {
            guardCount += 1
            if isPiBranded(pid) { return pid }
            guard let parent = parentPID(pid), parent != pid else { break }
            pid = parent
        }
        return nil
    }

    /// Walks the ancestry for the nearest interpreter that identifies a real
    /// agent — by a custom `argv[0]` (an agent that runs `node` but renames
    /// itself "pi"), the script it runs, or the module it runs (`python -m
    /// hermes_cli.main`) — skipping this skill's own plumbing. So a
    /// `node`-based agent shows as "pi" rather than "node". `stopBefore`
    /// bounds the walk below the responsible process (exclusive), keeping a
    /// launcher's or a signed agent app's own scripts out of consideration;
    /// nil walks the full ancestry — the bare-interpreter fallback, where a
    /// walk finding only the skill's own scripts (a detached mirror daemon
    /// whose spawning session's ancestry is gone) identifies the skill
    /// itself, stably keyed by its directory, rather than the interpreter's
    /// meaningless ad-hoc id. Returns nil when nothing better is found.
    private static func scriptIdentity(startingAt peerPID: pid_t,
                                       stopBefore boundary: pid_t? = nil) -> AgentIdentity? {
        var pid = peerPID
        var guardCount = 0
        var ownPlumbingExe: String?
        while pid > 1 && guardCount < 32 {
            guardCount += 1
            if let boundary, pid == boundary { break }
            if let exe = executablePath(pid),
               isScriptInterpreterName((exe as NSString).lastPathComponent),
               let argv = processArgv(pid) {
                if let identity = interpreterIdentity(argv: argv, exe: exe, pid: pid) {
                    return identity
                }
                if ownPlumbingExe == nil, isOwnPlumbing(argv: argv) {
                    ownPlumbingExe = exe
                }
            }
            guard let parent = parentPID(pid), parent != pid else { break }
            pid = parent
        }
        // Below a real responsible process, the launcher above is the better
        // identity than the skill's own plumbing.
        guard boundary == nil, let ownPlumbingExe else { return nil }
        // Nothing but our own scripts, all the way up: the walk did not find
        // an agent, so it says that rather than naming the scripts as one
        // (see AgentIdentity.unresolvedOwnPlumbing).
        return .unresolvedOwnPlumbing(executablePath: ownPlumbingExe)
    }

    /// Identity of one interpreter process: prefers a custom `argv[0]` the
    /// agent branded itself with (e.g. Pi launches `node` with argv[0]="pi"),
    /// else the script file it runs, else the module it runs. Returns nil for
    /// a plain interpreter or this skill's own plumbing, so the walk keeps
    /// looking upward.
    private static func interpreterIdentity(argv: [String], exe: String,
                                            pid: pid_t) -> AgentIdentity? {
        guard let arg0 = argv.first else { return nil }
        if isOwnPlumbing(argv: argv) { return nil }
        let interpreterName = (exe as NSString).lastPathComponent
        let arg0Name = (arg0 as NSString).lastPathComponent
        // (1) Custom argv[0] branding: a bare name (not a path) that isn't the
        //     interpreter's own — the agent's self-declared identity.
        if !arg0.contains("/"), !arg0Name.isEmpty, arg0Name != interpreterName,
           !isScriptInterpreterName(arg0Name) {
            return unsignedIdentity(name: arg0Name, path: arg0Name, exe: exe, pid: pid)
        }
        // (2) Otherwise the script it runs.
        if let script = scriptArgument(in: argv) {
            return unsignedIdentity(
                name: deriveAgentName(fromPath: script), path: script, exe: exe, pid: pid)
        }
        // (3) Otherwise a python-style module run (`python -m hermes_cli.main`,
        //     the hermes gateway) — no script file on disk to name it by.
        if let module = moduleArgument(in: argv) {
            let name = moduleAgentName(module)
            return unsignedIdentity(name: name, path: name, exe: exe, pid: pid)
        }
        return nil
    }

    /// The module of a `python -m <module>` invocation: `-m`'s value, but
    /// only when no positional (script/command) argument precedes it.
    private static func moduleArgument(in argv: [String]) -> String? {
        var expectModule = false
        for arg in argv.dropFirst() {
            if expectModule { return arg.isEmpty ? nil : arg }
            if arg == "-m" { expectModule = true; continue }
            if arg.hasPrefix("-") { continue }
            return nil
        }
        return nil
    }

    /// A readable agent name from a module path: the top package, shorn of a
    /// CLI-wrapper suffix. "hermes_cli.main" → "hermes".
    private static func moduleAgentName(_ module: String) -> String {
        var name = module.split(separator: ".").first.map(String.init) ?? module
        for suffix in ["_cli", "-cli", "_agent", "-agent"]
        where name.hasSuffix(suffix) && name.count > suffix.count {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name
    }

    /// This skill's own plumbing is never presented as the agent. The heredoc
    /// runner is recognized by the script it runs; the mirror-tailer daemon
    /// by its argv[0] brand — its `process.title` rewrite overwrites the argv
    /// block, so the script path is unreadable for it.
    private static func isOwnPlumbing(argv: [String]) -> Bool {
        if let arg0 = argv.first,
           ownBrandNames.contains((arg0 as NSString).lastPathComponent) {
            return true
        }
        if let script = scriptArgument(in: argv) { return isOwnRunner(script) }
        return false
    }

    /// argv[0] brands used by the skill's own daemons (see mirror-tailer.mjs)
    /// and the phibrowser CLI (a thin command surface over the same helper
    /// lib — like the heredoc runner, it acts for whoever drives it).
    private static let ownBrandNames: Set<String> = [
        "phi-mirror-tailer", "phibrowser-cli",
    ]

    /// The script an interpreter runs: its first existing non-flag argument.
    private static func scriptArgument(in argv: [String]) -> String? {
        for arg in argv.dropFirst() {
            if arg.hasPrefix("-") { continue }
            if FileManager.default.fileExists(atPath: arg) { return arg }
        }
        return nil
    }

    private static func unsignedIdentity(name: String, path: String,
                                         exe: String, pid: pid_t?) -> AgentIdentity {
        AgentIdentity(key: "unsigned:\(path)", displayName: name,
                      teamId: nil, verified: false, executablePath: exe, pid: pid)
    }

    /// This skill's own plumbing (heredoc runner, mirror-tailer daemon) —
    /// skipped when walking for the agent so we identify the launcher above
    /// it, not our own scripts. Matches both the installed skill directory
    /// ("phi-browser") and a repo checkout ("phi-browser-skill"), which Node
    /// exposes via realpath when the install is a symlink.
    private static func isOwnRunner(_ scriptPath: String) -> Bool {
        scriptPath.contains("/phi-browser/scripts/")
            || scriptPath.contains("/phi-browser-skill/scripts/")
    }

    /// A readable agent name from a script/executable path: the npm package
    /// name when under `node_modules`, else a meaningful file stem, else the
    /// nearest meaningful parent directory. `.../pi/cli.js` → "pi".
    static func deriveAgentName(fromPath path: String) -> String {
        if let r = path.range(of: "/node_modules/") {
            let comps = path[r.upperBound...].split(separator: "/").map(String.init)
            if let first = comps.first {
                if first.hasPrefix("@"), comps.count >= 2 { return comps[1] }
                return first
            }
        }
        let generic: Set<String> = [
            "cli", "index", "main", "bin", "dist", "build", "src", "lib",
            "run", "start", "runner", "server", "app", "out", "node_modules",
        ]
        let base = (path as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        if !stem.isEmpty, !generic.contains(stem.lowercased()) { return stem }
        var dir = (path as NSString).deletingLastPathComponent
        for _ in 0..<5 {
            let comp = (dir as NSString).lastPathComponent
            if comp.isEmpty { break }
            let bare = comp.hasPrefix(".") ? String(comp.dropFirst()) : comp
            if !bare.isEmpty, !generic.contains(bare.lowercased()) { return bare }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return stem.isEmpty ? base : stem
    }

    /// A process's argv (see processArgsAndEnv).
    private static func processArgv(_ pid: pid_t) -> [String]? {
        processArgsAndEnv(pid)?.argv
    }

    /// The executable path the kernel recorded for `pid` when it exec'd.
    /// Unlike `proc_pidpath` this still answers after the binary is unlinked
    /// or replaced on disk, which is what the first-party fallback needs.
    private static func recordedExecutablePath(_ pid: pid_t) -> String? {
        guard let path = processArgsAndEnv(pid)?.execPath, !path.isEmpty else { return nil }
        return path
    }

    /// True when `pid`'s exec-time environment carries pi's session marker
    /// (`PI_CODING_AGENT=true`). Pi sets it at runtime, so it is ABSENT from
    /// pi's own snapshot but inherited by every child pi spawns — read it from
    /// the connecting peer, not from pi (see piIdentity).
    private static func environHasPiMarker(_ pid: pid_t) -> Bool {
        processArgsAndEnv(pid)?.env.contains("PI_CODING_AGENT=true") ?? false
    }

    /// True when `pid` is a pi process: a script interpreter that rewrote its
    /// argv[0] to the bare name "pi" (pi's `process.title = APP_NAME`, whose
    /// default is "pi"). The brand is visible on pi itself, so this identifies
    /// the pi pid a detached daemon claims, where the env marker is not (see
    /// piIdentity).
    private static func isPiBranded(_ pid: pid_t) -> Bool {
        guard let exe = executablePath(pid),
              isScriptInterpreterName((exe as NSString).lastPathComponent),
              let arg0 = processArgsAndEnv(pid)?.argv.first,
              !arg0.contains("/") else { return false }
        return (arg0 as NSString).lastPathComponent == "pi"
    }

    /// A process's argv and environment via `KERN_PROCARGS2` (same-uid
    /// processes only, which the ancestry always is). Layout: Int32 argc,
    /// exec_path, null padding, argc null-terminated argv strings, then the
    /// null-terminated environment strings ("KEY=VALUE"). The environment is
    /// the EXEC-time one: a variable a process sets on itself after exec is
    /// absent, but everything it inherited (and hands to its children) is
    /// present. Nil when unreadable — a process that exited, or a sandboxed
    /// peer whose seatbelt denies the sysctl.
    private static func processArgsAndEnv(_ pid: pid_t)
        -> (execPath: String, argv: [String], env: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 4 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { dst in
            buffer.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[0..<4]))
            }
        }
        var pos = MemoryLayout<Int32>.size
        func nextString() -> String? {
            guard pos < size else { return nil }
            let start = pos
            while pos < size && buffer[pos] != 0 { pos += 1 }
            let s = String(decoding: buffer[start..<pos], as: UTF8.self)
            pos += 1  // skip the null terminator
            return s
        }
        let execPath = nextString() ?? ""
        while pos < size && buffer[pos] == 0 { pos += 1 } // padding before argv[0]
        var args: [String] = []
        for _ in 0..<Int(argc) {
            guard let s = nextString() else { break }
            args.append(s)
        }
        var env: [String] = []
        while let s = nextString() {
            if !s.isEmpty { env.append(s) }
        }
        return (execPath, args, env)
    }

    /// True when the socket peer runs under the same uid as this process. The
    /// coarse gate that keeps other local users out before any consent logic.
    static func peerIsSameUser(socketFD: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(socketFD, &uid, &gid) == 0 else { return false }
        return uid == getuid()
    }

    /// Stable for one launch of the resolved driving agent, including when
    /// several short-lived/sandboxed helper processes connect on its behalf.
    /// The start timestamp prevents a recycled pid from inheriting the prior
    /// agent session's task principal.
    static func processSessionAnchor(for identity: AgentIdentity) -> String? {
        guard let pid = identity.pid else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        guard rc == size else { return nil }
        return "\(identity.key)|\(pid)|\(info.pbi_start_tvsec)|\(info.pbi_start_tvusec)"
    }

    // MARK: - Consent prompt details

    /// How far up the ancestry the prompt's tree goes. Deep enough for the
    /// shapes agents actually arrive in (agent → shell → terminal → launchd,
    /// or an editor's helper stack) without letting a pathological chain push
    /// the alert past the height it scrolls at.
    private static let maxTreeDepth = 10

    /// The command line and launch chain behind `identity`, for the consent
    /// prompt's "Details" disclosure — or nil when there is nothing to show.
    ///
    /// Read at prompt time rather than at resolve time: the peer is blocked on
    /// the answer, so its ancestry is still live, and the many connections an
    /// agent makes per task would otherwise each pay for a walk nobody looks
    /// at. Runs synchronous sysctls — call it off the main thread.
    ///
    /// Everything here is best effort. A process that exits mid-walk, or one
    /// whose argv the kernel won't hand over, drops to its executable path
    /// rather than dropping the whole disclosure: a partial chain still tells
    /// the user more than "unsigned" alone.
    static func processDetails(for identity: AgentIdentity) -> AgentProcessDetails? {
        guard let agentPID = identity.pid else {
            // No live process behind the identity (the skill's own plumbing,
            // or a peer that has gone). The executable is all that is left,
            // and an empty path is not worth a disclosure row.
            guard !identity.executablePath.isEmpty else { return nil }
            return AgentProcessDetails(command: identity.executablePath,
                                       executablePath: identity.executablePath,
                                       tree: [])
        }

        var chain: [AgentProcessNode] = []
        var pid = agentPID
        var guardCount = 0
        while pid > 0 && guardCount < maxTreeDepth {
            guardCount += 1
            chain.append(processNode(pid, agentIdentity: pid == agentPID ? identity : nil))
            guard let parent = parentPID(pid), parent != pid else { break }
            pid = parent
        }

        let agentCommand = chain.first?.command
            ?? (identity.executablePath.isEmpty ? nil : identity.executablePath)
        guard let agentCommand else { return nil }
        return AgentProcessDetails(
            command: agentCommand,
            executablePath: executablePath(agentPID) ?? identity.executablePath,
            // Walked from the agent upward; shown from the top down.
            tree: chain.reversed())
    }

    /// One row of the tree. Named by `argv[0]` when the process branded itself
    /// with a bare name (how pi and other agents present themselves, and the
    /// same signal the identity walk trusts), else by its executable.
    ///
    /// `agentIdentity` is non-nil for the one row that IS the agent, and is
    /// the identity already resolved for it — which is better than what a
    /// signature check on that pid alone would say, since the resolve walk
    /// names a script-run agent by its script rather than by its interpreter's
    /// meaningless ad-hoc id. Every other row is identified from its signature
    /// here, and pays a `SecCode` check for it; that cost is why this runs on
    /// the about-to-prompt path and not per connection.
    private static func processNode(_ pid: pid_t,
                                    agentIdentity: AgentIdentity?) -> AgentProcessNode {
        let exe = executablePath(pid) ?? recordedExecutablePath(pid)
        let exeName = exe.map { ($0 as NSString).lastPathComponent }
        let argv = processArgv(pid)
        var name = exeName ?? "pid \(pid)"
        if let arg0 = argv?.first, !arg0.contains("/"), !arg0.isEmpty {
            name = arg0
        }
        let command = argv.map(commandLine(from:)).flatMap { $0.isEmpty ? nil : $0 }
            ?? exe
            ?? NSLocalizedString("agentControl.connectionApproval.details.commandUnavailable", value: "(command unavailable)", comment: "CDP consent - shown in the details disclosure when a process's command line cannot be read")
        return AgentProcessNode(
            pid: pid,
            name: name,
            command: command,
            isAgent: agentIdentity != nil,
            identity: agentIdentity ?? exe.map { signingIdentity(pid: pid, executablePath: $0) })
    }

    /// Every identity this connection could be decided by, most specific
    /// first: the agent that asked, then the processes that launched it,
    /// nearest first.
    ///
    /// The list exists because the prompt lets the user answer about an
    /// ancestor instead of the agent — the useful move when the agent is an
    /// unsigned script and the signed app above it is the thing they actually
    /// recognise. An answer recorded that way is only worth anything if the
    /// next connection finds it, which is what `AgentCDPListener` walks this
    /// list to do.
    ///
    /// Deduped by key, keeping the most specific occurrence: an agent whose
    /// signature matches its launcher's is one decision, not two.
    /// Non-selectable rows are left out — a grant can never be recorded under
    /// one, so matching against it could only ever surprise.
    static func decisionCandidates(for identity: AgentIdentity,
                                   details: AgentProcessDetails?) -> [AgentIdentity] {
        var seen = Set([identity.key])
        var candidates = [identity]
        // The tree is stored oldest-first for drawing; specificity runs the
        // other way.
        for node in (details?.tree ?? []).reversed() {
            guard node.isSelectableSubject, let nodeIdentity = node.identity,
                  seen.insert(nodeIdentity.key).inserted else {
                continue
            }
            candidates.append(nodeIdentity)
        }
        return candidates
    }

    /// argv rendered as a copyable one-liner. Arguments carrying whitespace are
    /// quoted, so a single path with a space in it doesn't read as two
    /// arguments — the detail that decides whether a command looks right.
    /// Internal for unit coverage.
    static func commandLine(from argv: [String]) -> String {
        argv.map { argument in
            guard argument.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else {
                return argument
            }
            return "\"\(argument.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        .joined(separator: " ")
    }

    // MARK: - Peer credentials

    private static func peerProcessID(socketFD: Int32) -> pid_t? {
        var pid: pid_t = -1
        var len = socklen_t(MemoryLayout<pid_t>.size)
        let rc = getsockopt(socketFD, SOL_LOCAL, LOCAL_PEERPID, &pid, &len)
        guard rc == 0, pid > 0 else { return nil }
        return pid
    }

    // MARK: - Ancestry walk

    /// The responsible process is the nearest ancestor (starting at the peer)
    /// that is either a signed `.app` bundle or a non-interpreter binary — the
    /// launcher (agent CLI, its app, or the terminal running it), not the
    /// `node`/shell plumbing in between. An Electron/Chromium helper bundle
    /// nested inside another app is plumbing too — passed through to the
    /// outer app, and used only as the fallback when no real launcher sits
    /// above it (an orphaned helper). Falls back to the peer itself.
    private static func responsiblePID(startingAt peerPID: pid_t) -> pid_t {
        var pid = peerPID
        var guardCount = 0
        var helperFallback: pid_t?
        while pid > 1 && guardCount < 32 {
            guardCount += 1
            let path = executablePath(pid)
            if isResponsible(pid: pid, executablePath: path) {
                return pid
            }
            if helperFallback == nil, let path, isNestedHelperBundle(path) {
                helperFallback = pid
            }
            guard let parent = parentPID(pid), parent != pid else { break }
            pid = parent
        }
        return helperFallback ?? peerPID
    }

    private static func isResponsible(pid: pid_t, executablePath path: String?) -> Bool {
        guard let path else { return false }
        // A helper bundle nested inside another app hosts that app's work —
        // and Electron builds often leave it generically signed (Cursor's
        // plugin helper is literally "com.github.Electron.helper"). The outer
        // app is the identity.
        if isNestedHelperBundle(path) { return false }
        // A signed application bundle is a strong, verifiable identity.
        if path.contains(".app/Contents/MacOS/") { return true }
        let name = (path as NSString).lastPathComponent
        return !isPassthroughName(name)
    }

    /// True for an executable whose bundle is nested inside another app
    /// bundle (…/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/
    /// Contents/MacOS/…) — the Electron/Chromium helper-process shape.
    private static func isNestedHelperBundle(_ path: String) -> Bool {
        guard let outer = path.range(of: ".app/Contents/") else { return false }
        return path[outer.upperBound...].contains(".app/Contents/MacOS/")
    }

    private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        if rc == size { return pid_t(info.pbi_ppid) }
        // proc_pidinfo is denied (EPERM) for another user's process — notably
        // the setuid-root `login` that sits above every Terminal tab, which
        // would end the walk before the terminal application is reached and
        // misresolve a terminal-run CLI. The kernel process table via sysctl
        // is world-readable (it is what `ps` uses), so fall back to it.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var kpSize = MemoryLayout<kinfo_proc>.stride
        let ok = withUnsafeMutablePointer(to: &kp) { kpPtr in
            sysctl(&mib, 4, kpPtr, &kpSize, nil, 0)
        }
        guard ok == 0, kpSize > 0 else { return nil }
        return kp.kp_eproc.e_ppid
    }

    /// Effective uid of a process, nil when it can't be read (process gone).
    private static func processUID(_ pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        guard rc == size else { return nil }
        return uid_t(info.pbi_uid)
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Code signature

    private static func signingIdentity(pid: pid_t,
                                        executablePath path: String) -> AgentIdentity {
        // Prompts show the app's user-facing bundle name when there is one:
        // signing identifiers of modern app builds are often opaque ids the
        // user would not recognize (Cursor's is "com.todesktop.230313…"), and
        // for a helper-bundle fallback the OUTERMOST bundle is the product
        // ("Cursor", not "Cursor Helper (Plugin)"). Grant keys stay on the
        // signature, which is the stable, verifiable part.
        let bundleName = appBundleName(forExecutablePath: path)
        let fallbackName = bundleName ?? (path as NSString).lastPathComponent
        let unsigned = AgentIdentity(
            key: "unsigned:\(path)",
            displayName: fallbackName,
            teamId: nil,
            verified: false,
            executablePath: path,
            pid: pid)

        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else {
            return unsigned
        }
        // Reject an invalid/broken signature; an unsigned-but-running binary
        // also lands here and is reported as unsigned.
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else {
            return unsigned
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return unsigned
        }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any] else {
            return unsigned
        }

        // An ad-hoc signature attests nothing: any locally built binary
        // carries one (linker-signed), and uv-managed pythons even share the
        // literal identifier "-" — presenting that as a verified name would
        // both mislead the prompt and key one agent's remembered grant to
        // every other ad-hoc binary. Report it as unsigned instead, keyed by
        // executable path.
        if let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value,
           SecCodeSignatureFlags(rawValue: flags).contains(.adhoc) {
            return unsigned
        }
        let signingId = (info[kSecCodeInfoIdentifier as String] as? String)
            .flatMap { $0 == "-" ? nil : $0 }
        let teamId = info[kSecCodeInfoTeamIdentifier as String] as? String
        let key: String
        if let teamId, !teamId.isEmpty, let signingId, !signingId.isEmpty {
            key = "\(teamId):\(signingId)"
        } else if let signingId, !signingId.isEmpty {
            key = "signed:\(signingId)"
        } else {
            return unsigned
        }
        return AgentIdentity(
            key: key,
            displayName: bundleName ?? signingId ?? fallbackName,
            teamId: teamId,
            signingId: signingId,
            verified: true,
            executablePath: path,
            pid: pid)
    }

    /// The outermost `.app` bundle's user-facing name for an executable
    /// inside one ("Cursor", "Terminal"), nil for a bare binary.
    private static func appBundleName(forExecutablePath path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        let bundlePath = String(path[..<range.lowerBound]) + ".app"
        let info = Bundle(path: bundlePath)?.infoDictionary
        if let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String), !name.isEmpty {
            return name
        }
        let dirName = ((bundlePath as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        return dirName.isEmpty ? nil : dirName
    }
}
