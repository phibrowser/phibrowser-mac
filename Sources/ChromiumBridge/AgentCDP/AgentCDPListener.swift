// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Darwin
import Foundation

/// Owns the Unix-domain socket that agent tooling (Claude Code, Codex, the
/// phi-browser skill) uses to reach the browser's DevTools/CDP endpoint.
///
/// The browser process listens on nothing: this app owns the listener,
/// authenticates every connecting process, prompts for the user's consent the
/// first time an agent appears, and hands each approved connection to Chromium
/// as a bare file descriptor via `attachDevToolsConnectionWithFD:`. Because the
/// app owns the socket, access can be revoked instantly
/// (`closeAllDevToolsConnections`).
///
/// The socket is up for the whole app session — it is a doorbell, not the
/// door. The two master switches (Developer mode, and agent CDP access under
/// Settings ▸ Developer) are enforced at consent time instead of by hiding the
/// endpoint: with either one off, a connecting agent still reaches the prompt,
/// which then asks to turn them on as part of allowing that agent. An agent
/// therefore never has to talk the user through Settings, and "off" still
/// means no agent can drive the browser until the user says so.
///
/// Two peers never reach the prompt at all, at opposite ends: the browser's own
/// agent runtime, which is admitted as part of the product (`firstPartyAgent`),
/// and a peer whose process cannot be identified, which is refused outright —
/// there is nothing to put in front of the user, and every such peer would
/// share one key, so a single "Always Allow" would approve all of them forever.
/// The second covers the skill's own plumbing when the walk finds nothing above
/// it: those scripts act for whoever drives them, so failing to find the driver
/// is what happened, not "an agent named phi-browser is asking".
///
/// A doorbell anyone may ring needs a way to silence it, so the prompt's deny
/// side is scoped too: this connection, 30 minutes, or never again, for the
/// asking agent or for every agent. Those refusals (`AgentDenial`) outrank
/// every grant and are checked before anything else.
///
/// A prompt can also be answered about the wrong thing, which is the other way
/// a user gets stuck: the process that reaches the socket is often an unsigned
/// script, and the thing they actually recognise is the signed application that
/// launched it. The prompt's Details disclosure shows that launch chain, with
/// each process's signing identity, and lets the answer be recorded against a
/// process in it instead. `answerFromLaunchChain` is the other half — without
/// it a grant given to a terminal would be found by nothing and the same
/// prompt would come back. The rule between the two tiers: the most specific
/// decision wins, and a launcher decides only what the agent under it has no
/// decision of its own about.
///
/// The allow side can be widened the same way — "Apply to all agents" turns
/// Allow Once / Always Allow into a blanket grant that admits agents never seen
/// before, session-scoped or persisted
/// (`PhiPreferences.AgentSpaces.allAgentsGranted`). Settings ▸ Developer
/// carries the same grant as a switch over the allowed-agent list, so it can be
/// given and taken back without waiting for an agent to ask. It is the widest
/// permission here and the one thing that makes the prompt stop appearing, so
/// it is off by default, still bounded by the two master switches, and still
/// outranked by every refusal.
///
/// Threading: the accept loop runs on `ioQueue`; each connection is
/// authenticated on the serial `authQueue` (which also serializes consent
/// prompts and caches their result, so the skill's back-to-back HTTP + WebSocket
/// connections prompt at most once); the bridge hand-off and the modal prompt
/// hop to the main thread.
final class AgentCDPListener {
    static let shared = AgentCDPListener()

    private let ioQueue = DispatchQueue(label: "com.phibrowser.cdp.listener")
    private let authQueue = DispatchQueue(label: "com.phibrowser.cdp.auth")

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var socketPath: String?
    private var pointerFilePath: String?
    private var running = false

    // "Allow once" decisions for this app session, keyed by AgentIdentity.key.
    // Persisted grants live in PhiPreferences.rememberedAgentGrants.
    private var sessionGrants = Set<String>()
    // The same, widened to every agent: an "Allow Once" answered with "Apply
    // to all agents". Its persisted counterpart is
    // PhiPreferences.allAgentsGranted, which this mirrors once observed so the
    // rest of the session needs no defaults read.
    private var sessionAllAgentsGrant = false
    // Agents admitted this session on a grant the user recorded against one of
    // the processes that LAUNCHED them, rather than one of their own: agent
    // key -> that launcher's key. A shortcut past re-walking the ancestry, not
    // a grant (see admittedByStandingLaunchChain).
    private var launchChainAdmissions = [String: String]()
    // The agent process whose first-party pass this launch has already logged
    // (see logFirstPartyPass).
    private var loggedFirstPartyPassPid: pid_t?
    private let grantsLock = NSLock()

    private init() {}

    // MARK: - Lifecycle

    /// Whether an approved agent may drive the browser right now: Developer
    /// mode (Settings ▸ General) and agent CDP access (Settings ▸ Developer)
    /// must both be on. With either off the socket still accepts — the
    /// consent prompt turns into a request to open both (see `evaluate`).
    private static var accessGatesOpen: Bool {
        PhiPreferences.AgentSpaces.developerModeEnabled
            && PhiPreferences.AgentSpaces.cdpAgentAccessEnabled
    }

    /// Flips the preference and applies it live, with no relaunch. Call from
    /// the Settings toggle. Turning it off severs every live connection at
    /// once; the socket itself stays up either way, so the next agent to
    /// connect can ask for it back. Also refreshes the main menu, whose
    /// View ▸ Agent Autoview / Agent Transcript items are gated on this switch.
    ///
    /// - Parameter resettingRefusals: whether turning access ON also lifts
    ///   every standing refusal. True for the Settings toggle — flipping the
    ///   master switch back on is a clean slate, and the second way out of a
    ///   "Never ask again, all agents" block after the Blocked agents list.
    ///   False when one agent's approval is what turns the feature on
    ///   (`openAccessGates`): allowing that agent must not unblock the others.
    func setEnabled(_ enabled: Bool, resettingRefusals: Bool = true) {
        PhiPreferences.AgentSpaces.cdpAgentAccessEnabled = enabled
        if enabled {
            if resettingRefusals {
                PhiPreferences.AgentSpaces.agentDenials = []
            }
        } else {
            revokeActiveAccess()
        }
        DispatchQueue.main.async {
            AppController.shared?.refreshPrefGatedMenuItems()
            // No agent can drive with the switch off, so an open transcript
            // panel is a dead surface — take it down with the menu items.
            if !enabled {
                AgentTranscriptPanelController.shared.dismiss()
            }
            NotificationCenter.default.post(name: .agentCDPAccessDidChange, object: nil)
        }
    }

    func start() {
        ioQueue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        ioQueue.async { [weak self] in self?.stopOnQueue() }
    }

    /// Forgets an agent grant (Settings ▸ revoke): drops it from both the
    /// remembered set and this session's cache, so the identity must pass the
    /// consent prompt again on its next connection. Already-attached
    /// connections persist until they close (flip the master toggle to sever
    /// everything at once).
    func forgetGrant(key: String) {
        var remembered = PhiPreferences.AgentSpaces.rememberedAgentGrants
        remembered.remove(key)
        PhiPreferences.AgentSpaces.rememberedAgentGrants = remembered
        grantsLock.lock()
        sessionGrants.remove(key)
        grantsLock.unlock()
    }

    /// Forgets every agent approval at once — the persisted "Always Allow"
    /// grants, this session's "Allow Once" ones, and the blanket "all agents"
    /// grant in both flavors. The developer-mode kill-switch calls it: turning
    /// developer mode off doesn't just close the door, it forgets everyone who
    /// was ever let in, so each agent has to pass consent from scratch
    /// afterwards. Denials are deliberately kept — clearing approvals must
    /// never soften a refusal.
    func forgetAllGrants() {
        PhiPreferences.AgentSpaces.rememberedAgentGrants = []
        PhiPreferences.AgentSpaces.allAgentsGranted = false
        grantsLock.lock()
        sessionGrants.removeAll()
        sessionAllAgentsGrant = false
        launchChainAdmissions.removeAll()
        grantsLock.unlock()
    }

    /// Every *named* agent allowed to connect: the persisted "Always Allow"
    /// grants plus this session's "Allow Once" grants. Backs the Developer
    /// settings list. The blanket grant is deliberately absent — it is the
    /// switch above this list, not a row in it (`allAgentsGranted`). Safe to
    /// call from the main thread.
    func allowedGrants() -> [AgentGrant] {
        let remembered = PhiPreferences.AgentSpaces.rememberedAgentGrants
        grantsLock.lock()
        let session = sessionGrants
        grantsLock.unlock()

        var grants: [AgentGrant] = remembered.sorted().map {
            AgentGrant(key: $0, remembered: true)
        }
        for key in session.subtracting(remembered).sorted() {
            grants.append(AgentGrant(key: key, remembered: false))
        }
        return grants
    }

    // MARK: - Blanket grant

    /// Whether a blanket "all agents" grant stands right now, in either
    /// flavor: persisted from Settings or from "Always Allow" widened at the
    /// prompt, and this session's from "Allow Once" widened the same way.
    /// Backs the Settings switch, which reads on for both.
    var allAgentsGranted: Bool {
        grantsLock.lock()
        let session = sessionAllAgentsGrant
        grantsLock.unlock()
        return session || PhiPreferences.AgentSpaces.allAgentsGranted
    }

    /// Whether the standing blanket grant lapses when the app quits — true
    /// only for one widened at the prompt with "Allow Once". Settings shows it
    /// as a "This session" pill, so a switch that reads on never implies a
    /// permanence it doesn't have.
    var allAgentsGrantIsSessionOnly: Bool {
        allAgentsGranted && !PhiPreferences.AgentSpaces.allAgentsGranted
    }

    /// Applies the Settings ▸ Developer "Allow all agents" switch. A switch in
    /// Settings is a durable setting, so ON always persists — including when
    /// it merely confirms a session-only grant made at the prompt.
    ///
    /// Turning it on also lifts every standing refusal, for the same reason
    /// the master switch does: "allow all agents" is the widest answer the
    /// user can give, and leaving a refusal to silently outrank it would show
    /// a switch that is on while agents are still turned away. Turning it off
    /// only stops it deciding future connections — live connections persist
    /// until they close, exactly like revoking one agent's grant.
    func setAllAgentsGranted(_ granted: Bool) {
        PhiPreferences.AgentSpaces.allAgentsGranted = granted
        grantsLock.lock()
        sessionAllAgentsGrant = granted
        grantsLock.unlock()
        if granted {
            PhiPreferences.AgentSpaces.agentDenials = []
        }
        AppLogInfo("[AgentCDP] blanket all-agents grant "
                   + (granted ? "enabled" : "revoked") + " from Settings")
    }

    // MARK: - Socket setup (ioQueue)

    private func startOnQueue() {
        guard !running else { return }

        guard let paths = Self.resolveSocketPaths() else {
            AppLogError("[AgentCDP] could not resolve a socket path")
            return
        }

        Self.sweepOrphanedSocketDirs(
            keeping: (paths.socket as NSString).deletingLastPathComponent)
        guard Self.prepareSocketDirectory(for: paths.socket) else { return }
        unlink(paths.socket)  // clear a stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            AppLogError("[AgentCDP] socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        guard Self.bind(fd: fd, to: paths.socket) else {
            close(fd)
            return
        }
        chmod(paths.socket, 0o600)

        guard listen(fd, 16) == 0 else {
            AppLogError("[AgentCDP] listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            unlink(paths.socket)
            return
        }
        Self.setNonBlocking(fd)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()

        listenFD = fd
        acceptSource = source
        socketPath = paths.socket
        pointerFilePath = paths.pointer
        running = true

        // Publish the socket path for the skill's discovery (the file may live
        // at a long path; only bind() is bound by sun_path's ~104-byte limit).
        try? (paths.socket + "\n").write(toFile: paths.pointer, atomically: true, encoding: .utf8)

        AppLogInfo("[AgentCDP] listening at \(paths.socket)")
    }

    private func stopOnQueue() {
        guard running else { return }
        running = false

        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        if let socketPath { unlink(socketPath) }
        if let pointerFilePath { unlink(pointerFilePath) }
        socketPath = nil
        pointerFilePath = nil

        revokeActiveAccess()
        AppLogInfo("[AgentCDP] stopped")
    }

    /// Cuts every agent off immediately: both transports are severed
    /// (connections handed to Chromium and the app-served /phi-agent
    /// channels) and this session's Allow-Once grants are dropped — the
    /// blanket one included — so a reconnecting agent has to pass consent
    /// again. Persisted "Always Allow" grants survive: they are revoked from
    /// Settings, one entry at a time.
    private func revokeActiveAccess() {
        grantsLock.lock()
        sessionGrants.removeAll()
        sessionAllAgentsGrant = false
        grantsLock.unlock()

        AgentDirectChannelRegistry.shared.closeAll()
        DispatchQueue.main.async {
            ChromiumLauncher.sharedInstance().bridge?.closeAllDevToolsConnections()
        }
    }

    // MARK: - Accept loop (ioQueue)

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                // Drained the backlog (EAGAIN/EWOULDBLOCK) or a transient error.
                break
            }
            Self.setNonBlocking(fd)
            authQueue.async { [weak self] in self?.authenticateAndDispatch(fd) }
        }
    }

    // MARK: - Authentication (authQueue, serial)

    private func authenticateAndDispatch(_ fd: Int32) {
        guard AgentPeerIdentity.peerIsSameUser(socketFD: fd) else {
            AppLogWarn("[AgentCDP] rejecting connection from another user")
            Self.denyAndClose(fd)
            return
        }

        // Peek (never consume) the request head up front: the first line
        // routes the connection, and any request may carry the agent-session
        // pid claim used for the consent identity below.
        // A connection that never sent a request — a port probe, a liveness
        // check, a peer that hung up immediately — must not reach consent
        // evaluation: on this serial queue an unidentifiable peer would wedge
        // every legitimate connection behind whatever it costs to turn it
        // away. Close it quietly, before any of that.
        guard let requestHead = Self.peekRequestHead(fd) else {
            close(fd)
            return
        }
        let requestLine = requestHead
            .split(separator: "\r\n", maxSplits: 1).first
            .map(String.init)
        let isPhiAgent = requestLine?.hasPrefix("GET /phi-agent") ?? false

        // Resolve the actual peer ancestry first. Any connection may present
        // an app-issued capability from an earlier `/phi-agent` upgrade; that
        // is the proof that a detached/sandboxed helper was delegated the
        // logical agent session, and it binds this connection — task channel
        // or stock CDP alike — to that session's identity and grant. The
        // caller-supplied pid is a log-only identification aid: it neither
        // joins a Swift task principal nor substitutes the consent identity.
        // The browser's own agent runtime is recognized before any ancestry
        // walk: it is not one of the agents this consent system arbitrates
        // (see AgentPeerIdentity.firstPartyAgent), and resolving it normally
        // would only produce a version-stamped "phi-agent.bundle" identity to
        // prompt about. Every other peer falls through to the walk.
        let peerIdentity = AgentPeerIdentity.firstPartyAgent(socketFD: fd)
            ?? AgentPeerIdentity.resolve(socketFD: fd)
            ?? .unresolved

        let delegatedSession: AgentDriverSession?
        switch Self.capabilityClaim(inRequestHead: requestHead) {
        case .absent:
            delegatedSession = nil
        case .invalid:
            // Presenting a capability at all commits the connection to
            // capability auth — a malformed one never falls back to peer
            // identity, on any route.
            AppLogWarn("[AgentCDP] rejected malformed agent-session capability")
            Self.denyAndClose(fd)
            return
        case .valid(let capability):
            guard let session = AgentDriverSessionRegistry.shared
                    .session(forCapability: capability) else {
                AppLogWarn("[AgentCDP] rejected unknown agent-session capability")
                Self.denyAndClose(fd)
                return
            }
            delegatedSession = session
        }

        // Route by the request line: a `/phi-agent` upgrade is an agentSpace.*
        // channel served in the app; everything else (/json, /devtools) is
        // stock CDP handed to Chromium with the fd intact (the peek never
        // consumed it).
        if isPhiAgent {
            let session: AgentDriverSession
            if let delegatedSession {
                session = delegatedSession
                guard evaluate(session.identity) else {
                    AppLogInfo("[AgentCDP] denied delegated access to \(session.identity.displayName)")
                    Self.denyAndClose(fd)
                    return
                }
            } else {
                guard evaluate(peerIdentity) else {
                    AppLogInfo("[AgentCDP] denied access to \(peerIdentity.displayName)")
                    Self.denyAndClose(fd)
                    return
                }
                session = AgentDriverSessionRegistry.shared.session(for: peerIdentity)
            }
            AgentDirectConnection(
                fd: fd,
                agentName: session.identity.displayName,
                agentPid: session.identity.pid,
                driverPrincipalId: session.principalId,
                agentCapability: session.capability
            ).start()
            return
        }

        // Stock CDP consent follows the same session rules: a delegated
        // helper is evaluated as its session's identity; otherwise the peer's
        // OWN resolved ancestry decides. Naming another agent's pid therefore
        // cannot piggyback that agent's remembered grant onto raw CDP.
        let identity = delegatedSession?.identity ?? peerIdentity
        if delegatedSession == nil,
           let claimedPid = Self.claimedAgentPid(inRequestHead: requestHead),
           let claimed = AgentPeerIdentity.resolveClaimed(pid: claimedPid) {
            AppLogInfo("[AgentCDP] peer \(identity.displayName) claims agent pid "
                       + "\(claimedPid) (\(claimed.displayName)) — identification only")
        }

        guard evaluate(identity) else {
            AppLogInfo("[AgentCDP] denied access to \(identity.displayName)")
            Self.denyAndClose(fd)
            return
        }

        // Hand the raw fd to Chromium, which owns it from here (closed by the
        // browser whether or not the injection transport is live). Note who
        // opened it first: nothing downstream of the handover can say which
        // agent a browser-reported drive belongs to, so the operating mask's
        // pill names the driver from here — best effort, and only while one
        // agent is connected (AgentCDPDriverRoster).
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AgentCDPDriverRoster.shared.noteInjection(
                    key: identity.key, displayName: identity.displayName)
            }
            let attached = ChromiumLauncher.sharedInstance().bridge?
                .attachDevToolsConnection(withFD: fd) ?? false
            if !attached {
                AppLogWarn("[AgentCDP] injection transport unavailable; connection dropped")
            }
        }
    }

    /// Peeks (without consuming) at the start of the HTTP request — enough to
    /// cover the request line and the early headers that may carry the agent
    /// claim (the skill puts X-Phi-Agent-Pid right after Host). Non-consuming
    /// so a Chromium-bound fd stays pristine for its HTTP server to read from
    /// the start.
    private static func peekRequestHead(_ fd: Int32) -> String? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        _ = poll(&pfd, 1, 2000)  // up to 2s for the request to arrive
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = recv(fd, &buf, buf.count, Int32(MSG_PEEK))
        guard n > 0 else { return nil }
        return String(decoding: buf[0..<n], as: UTF8.self)
    }

    /// The agent-session pid a request claims to act for: an `agentPid` query
    /// value on the request line (e.g. "GET /phi-agent?agentPid=123
    /// HTTP/1.1") or an `X-Phi-Agent-Pid` header on any route.
    private static func claimedAgentPid(inRequestHead head: String) -> pid_t? {
        let lines = head.components(separatedBy: "\r\n")
        guard let line = lines.first else { return nil }
        let parts = line.split(separator: " ")
        if parts.count >= 2,
           let query = parts[1].split(separator: "?").dropFirst().first {
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "agentPid", let pid = pid_t(kv[1]) {
                    return pid
                }
            }
        }
        for header in lines.dropFirst() {
            if header.isEmpty { break }  // end of headers
            guard let colon = header.firstIndex(of: ":") else { continue }
            guard header[..<colon].lowercased() == "x-phi-agent-pid" else { continue }
            let value = header[header.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            return pid_t(value)
        }
        return nil
    }

    /// App-issued bearer capability proving that this connection belongs to
    /// an already-established logical driver session. Kept in a dedicated
    /// header so stock Chromium simply ignores it on its own connections.
    /// One parser answers both "is one present?" and "what is it?", so the
    /// routing decision and the value can never disagree.
    enum CapabilityClaim: Equatable {
        case absent
        case invalid
        case valid(String)
    }

    /// Scanning stops at the head/body boundary (a stray match in peeked body
    /// bytes is not a claim), and a malformed or duplicated header is
    /// `.invalid` — never silently ignored. Internal for unit coverage.
    static func capabilityClaim(inRequestHead head: String) -> CapabilityClaim {
        var found: String?
        for header in head.components(separatedBy: "\r\n").dropFirst() {
            if header.isEmpty { break }  // end of headers
            guard let colon = header.firstIndex(of: ":"),
                  header[..<colon].lowercased() == "x-phi-agent-capability" else {
                continue
            }
            if found != nil { return .invalid }  // duplicate header
            let value = header[header.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard value.count >= 32, value.count <= 128,
                  value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
                return .invalid
            }
            found = value
        }
        return found.map(CapabilityClaim.valid) ?? .absent
    }

    /// Returns true when `identity` may connect: a cached session grant, a
    /// remembered grant, a standing blanket grant, or a fresh Allow from the
    /// consent prompt.
    ///
    /// While a master switch is off no grant stands on its own — every agent,
    /// remembered or not, goes to the prompt, which asks to turn the switches
    /// back on as part of allowing it. That is the only path that flips them
    /// from outside Settings, and it always costs the user an explicit Allow.
    private func evaluate(_ identity: AgentIdentity) -> Bool {
        // The browser's own agent runtime is admitted before any of it. It is
        // not an agent this system arbitrates but a part of the product, shipped
        // and signed with the browser, and it reaches CDP only because that is
        // the transport it drives Spaces over. Everything below exists to
        // decide about OUTSIDE agents, and none of it fits: there is no one to
        // prompt (it starts with Sentinel, before anyone is at the keyboard),
        // no grant to remember (its identity is established per connection from
        // the code signature, not recalled from a list), and nothing the two
        // master switches should say about it — Developer mode gates handing
        // the browser to third-party tooling, not the browser's own features.
        //
        // Standing refusals are passed over for the same reason, and one more:
        // the blanket "all agents" refusal is recorded from a prompt about some
        // OTHER agent, so it was never a decision about this one — and with
        // Developer mode off the Blocked agents list that would lift it is not
        // even reachable, which would leave a built-in feature switched off
        // behind a setting the user can no longer see.
        if identity.firstParty {
            logFirstPartyPass(identity)
            return true
        }

        // A peer we could not identify is refused here, before any grant,
        // refusal, or prompt can apply to it — whether the socket would not
        // name a process at all, or the walk found nothing but the skill's own
        // plumbing with no agent above it.
        //
        // The prompt is the wrong instrument for either. Both arrive under the
        // same key, so an "Always Allow" would not approve a program — it
        // would approve being unidentifiable, for everyone, permanently,
        // leaving a row in Settings that names no one as the only thing to
        // revoke. And the prompt would have almost nothing to show: no launch
        // chain and no pid, because the missing pid is the whole problem.
        // Asking a question the user has no way to answer is worse than
        // answering it for them.
        //
        // Refusing costs little. Two guards upstream already turn away what
        // plausibly lands in the first case — a peer whose credentials cannot
        // be read fails the same-user check, and one that sends no request is
        // closed after the peek. And a genuine helper in the second still has
        // a way in that does not depend on the walk: the capability a
        // `/phi-agent` upgrade issues carries its session's identity, and a
        // connection presenting one is evaluated as THAT identity and never
        // reaches this line. Which is exactly what the log says, because a
        // helper arriving here has a delegation bug worth naming rather than a
        // permission the user should be pestered about.
        if identity.isUnresolved {
            AppLogWarn("[AgentCDP] refused \(identity.displayName)"
                       + (identity.executablePath.isEmpty
                          ? "" : " (\(identity.executablePath))")
                       + " — nothing about this connection identifies an agent;"
                       + " a helper acting for one must present its session capability")
            return false
        }

        // A standing refusal wins over everything, including a remembered or
        // blanket grant: "Never ask again" has to mean it even if the same
        // agent — or every agent — was once allowed.
        if let denial = Self.liveDenials().first(where: { $0.covers(identity.key) }) {
            AppLogInfo("[AgentCDP] refused \(identity.displayName) — standing denial"
                       + (denial.isPermanent ? " (never ask again)" : " (until \(denial.expires!))"))
            return false
        }

        grantsLock.lock()
        let granted = sessionGrants.contains(identity.key) || sessionAllAgentsGrant
        grantsLock.unlock()

        let gatesOpen = Self.accessGatesOpen
        if gatesOpen {
            if granted { return true }
            if PhiPreferences.AgentSpaces.allAgentsGranted {
                grantsLock.lock(); sessionAllAgentsGrant = true; grantsLock.unlock()
                return true
            }
            if PhiPreferences.AgentSpaces.rememberedAgentGrants.contains(identity.key) {
                grantsLock.lock(); sessionGrants.insert(identity.key); grantsLock.unlock()
                return true
            }
            // Last and least specific: an answer the user gave about whatever
            // launched this agent, already matched once this session.
            if admittedByStandingLaunchChain(identity) { return true }
        }

        // Nothing above decided, so the walk is worth paying for: it is what
        // the prompt's Details disclosure shows, and what the launchers the
        // user may already have answered about are found in.
        let details = AgentPeerIdentity.processDetails(for: identity)
        if let settled = answerFromLaunchChain(identity, details: details,
                                               gatesOpen: gatesOpen) {
            return settled
        }

        let decision = promptForConsent(identity, details: details,
                                        opensGates: !gatesOpen)
        let subject = decision.subject
        let retargeted = decision.isRetargeted(from: identity)
        if retargeted {
            AppLogInfo("[AgentCDP] answering for \(subject.displayName) instead of "
                       + "\(identity.displayName) — the user picked it out of the launch chain")
        }
        switch decision.choice {
        case .deny(let scope, let allAgents):
            if scope.isRemembered {
                recordDenial(AgentDenial(key: allAgents ? nil : subject.key,
                                         expires: scope.expiry))
            }
            return false

        case .allow(let remembered, let allAgents):
            // Open the gates before the caller hands the connection on, so the
            // browser is never driven while Settings still reads "off".
            if !gatesOpen { openAccessGates() }

            // A widened answer is recorded ONLY as the blanket grant: adding
            // the asking agent's own key underneath would outlive the blanket
            // one and quietly keep it connecting after the user revokes
            // "All agents".
            grantsLock.lock()
            if allAgents {
                sessionAllAgentsGrant = true
            } else {
                sessionGrants.insert(subject.key)
                // The grant is under the launcher's key, so this agent's next
                // connection would find nothing of its own and re-walk its
                // ancestry to rediscover what was just decided. Note it here
                // instead; it is still only a shortcut, re-checked against the
                // launcher's grant every time (admittedByStandingLaunchChain).
                if retargeted { launchChainAdmissions[identity.key] = subject.key }
            }
            grantsLock.unlock()

            if remembered {
                if allAgents {
                    PhiPreferences.AgentSpaces.allAgentsGranted = true
                } else {
                    var grants = PhiPreferences.AgentSpaces.rememberedAgentGrants
                    grants.insert(subject.key)
                    PhiPreferences.AgentSpaces.rememberedAgentGrants = grants
                }
            }
            if allAgents {
                AppLogInfo("[AgentCDP] granted access to all agents"
                           + (remembered ? " (always)" : " (this session)"))
            }
            return true
        }
    }

    /// Whether this agent has already been matched to a launcher's answer this
    /// session, and that answer still stands.
    ///
    /// The memo is a shortcut past the ancestry walk, never a grant of its
    /// own: the launcher's grant and any refusal against it are re-read on
    /// every connection, so revoking it in Settings stops the agent at once.
    /// Without it, an agent admitted this way would re-walk its whole chain —
    /// sysctls plus a signature check per ancestor — on every connection it
    /// makes, and a working agent makes many per task.
    private func admittedByStandingLaunchChain(_ identity: AgentIdentity) -> Bool {
        grantsLock.lock()
        let launcherKey = launchChainAdmissions[identity.key]
        let sessionGranted = launcherKey.map(sessionGrants.contains) ?? false
        grantsLock.unlock()

        guard let launcherKey,
              !Self.liveDenials().contains(where: { $0.key == launcherKey }) else {
            return false
        }
        return sessionGranted
            || PhiPreferences.AgentSpaces.rememberedAgentGrants.contains(launcherKey)
    }

    /// An answer the user already gave about one of the processes that
    /// launched this agent, or nil when they have not answered about any of
    /// them and the prompt has to be raised.
    ///
    /// This is the other half of the prompt letting the user answer about a
    /// parent process. A grant recorded against "Terminal" is worth nothing if
    /// the next connection resolves to the unsigned script under it and asks
    /// again, so a connection that no decision of its own covers is checked
    /// against the chain above it too.
    ///
    /// ## The rule this establishes
    ///
    /// **The most specific decision wins; a launcher decides only what the
    /// agent under it has no decision of its own about.** Everything before
    /// this point in `evaluate` is the agent's own tier — refusal first, then
    /// grants, so "Never ask again" still outranks "Always Allow" for the same
    /// identity. This is the tier below, and it repeats the same order among
    /// the launchers. So an agent the user allowed by name keeps working after
    /// they block the terminal it happens to run under, which is what
    /// answering about it *by name* meant.
    ///
    /// Nothing is cached onto the agent's own key from here. Caching would be
    /// faster, but it would turn a launcher's grant into a grant on the agent
    /// that outlives revoking the launcher's — and this path only runs on
    /// connections that were already about to open a modal dialog.
    private func answerFromLaunchChain(_ identity: AgentIdentity,
                                       details: AgentProcessDetails?,
                                       gatesOpen: Bool) -> Bool? {
        // The agent's own key led the list and was settled above; what is left
        // is the launchers, nearest first.
        let launchers = AgentPeerIdentity
            .decisionCandidates(for: identity, details: details)
            .dropFirst()
        guard !launchers.isEmpty else { return nil }

        let denials = Self.liveDenials()
        for launcher in launchers {
            // A blanket refusal is not a decision about this launcher — it was
            // recorded from a prompt about someone else, and the agent's own
            // tier has already had its say on it.
            if let denial = denials.first(where: { $0.key == launcher.key }) {
                AppLogInfo("[AgentCDP] refused \(identity.displayName) — standing denial for "
                           + "\(launcher.displayName), which launched it"
                           + (denial.isPermanent ? " (never ask again)" : " (until \(denial.expires!))"))
                return false
            }
            guard gatesOpen else { continue }
            grantsLock.lock()
            let sessionGranted = sessionGrants.contains(launcher.key)
            grantsLock.unlock()
            if sessionGranted
                || PhiPreferences.AgentSpaces.rememberedAgentGrants.contains(launcher.key) {
                grantsLock.lock()
                launchChainAdmissions[identity.key] = launcher.key
                grantsLock.unlock()
                AppLogInfo("[AgentCDP] admitted \(identity.displayName) on the grant for "
                           + "\(launcher.displayName), which launched it")
                return true
            }
        }
        return nil
    }

    /// Records the first-party pass once per agent process. The runtime makes
    /// many connections — the skill's HTTP and WebSocket rounds alone are
    /// several per task — so logging each would bury the log while saying
    /// nothing new. Keying on the pid rather than on the launch still collapses
    /// all of those to one line, while leaving a fresh one each time Sentinel
    /// restarts the agent: without that, a pass that quietly stopped applying
    /// looked exactly like one that was still working.
    private func logFirstPartyPass(_ identity: AgentIdentity) {
        grantsLock.lock()
        let alreadyLogged = loggedFirstPartyPassPid == identity.pid
        loggedFirstPartyPassPid = identity.pid
        grantsLock.unlock()
        guard !alreadyLogged else { return }
        AppLogInfo("[AgentCDP] admitted \(identity.displayName) (pid \(identity.pid.map(String.init) ?? "?")) "
                   + "on the first-party pass — Phi-signed runtime, no consent required")
    }

    // MARK: - Standing refusals

    /// The refusals still in force, pruning lapsed ones on the way out (and
    /// writing the pruned list back, so an expired entry doesn't linger in the
    /// Settings list). Reads and writes are serialized by `authQueue` on the
    /// consent path; the Settings list only removes.
    private static func liveDenials() -> [AgentDenial] {
        let all = PhiPreferences.AgentSpaces.agentDenials
        let live = all.filter { !$0.isExpired }
        if live.count != all.count {
            PhiPreferences.AgentSpaces.agentDenials = live
        }
        return live
    }

    /// Records a refusal, dropping any it makes redundant and skipping itself
    /// when a broader or longer one already stands — so choosing "never, all
    /// agents" collapses the list to one entry instead of stacking.
    private func recordDenial(_ denial: AgentDenial) {
        var denials = Self.liveDenials()
        denials.removeAll { denial.supersedes($0) }
        if !denials.contains(where: { $0.supersedes(denial) }) {
            denials.append(denial)
        }
        PhiPreferences.AgentSpaces.agentDenials = denials
        AppLogInfo("[AgentCDP] recorded denial for "
                   + (denial.appliesToAllAgents ? "all agents" : denial.displayName)
                   + (denial.isPermanent ? " (never ask again)" : " (30 min)"))
    }

    /// Standing refusals, for the Developer settings "Blocked agents" list.
    /// Safe to call from the main thread.
    func blockedAgents() -> [AgentDenial] {
        Self.liveDenials().sorted { lhs, rhs in
            if lhs.appliesToAllAgents != rhs.appliesToAllAgents {
                return lhs.appliesToAllAgents  // the broadest entry leads
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Lifts one refusal (Settings ▸ unblock), so that agent is prompted for
    /// again on its next connection.
    func forgetDenial(id: String) {
        PhiPreferences.AgentSpaces.agentDenials =
            Self.liveDenials().filter { $0.id != id }
    }

    /// Turns on Developer mode and agent CDP access after the user approved a
    /// prompt that said it would. Developer mode goes through AppController,
    /// which owns that toggle's side effects (rebuilding an open Settings
    /// window so the Developer tab appears).
    private func openAccessGates() {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                AppController.shared?.setDeveloperModeEnabled(true)
            }
        }
        setEnabled(true, resettingRefusals: false)
        AppLogInfo("[AgentCDP] developer mode and agent CDP access enabled from the consent prompt")
    }

    /// The one prompt an agent ever triggers. `opensGates` adds the banner
    /// saying that allowing also switches the feature on, so the user is never
    /// sent to Settings to finish what they just approved. Its deny options
    /// are the other half of that bargain: a prompt that can turn the feature
    /// on has to be answerable with "and stop asking".
    ///
    /// `details` is the peer's command and launch chain, read on `authQueue`
    /// by the caller — a run of synchronous sysctls and signature checks that
    /// must not land on the main thread, and which the caller has already
    /// consulted (see `answerFromLaunchChain`). The alert shows it behind
    /// Details, and lets the user answer about a process in it instead of the
    /// agent, which is why the answer comes back with a subject.
    ///
    /// Any other dismissal (the host window closing) reads as a plain deny of
    /// the asking agent — the one answer that changes nothing.
    private func promptForConsent(_ identity: AgentIdentity,
                                  details: AgentProcessDetails?,
                                  opensGates: Bool) -> AgentAccessDecision {
        var decision = AgentAccessDecision(
            choice: .deny(scope: .thisTime, allAgents: false), subject: identity)
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                _ = NSApp.runPhiAlert { dismiss in
                    AgentAccessApprovalAlert(
                        agent: identity,
                        opensGates: opensGates,
                        processDetails: details
                    ) { picked in
                        decision = picked
                        dismiss(.alertFirstButtonReturn)
                    }
                }
            }
        }
        return decision
    }

    // MARK: - Helpers

    private struct SocketPaths {
        let socket: String
        let pointer: String
    }

    /// Stable per-bundle suffix (FNV-1a of the bundle id). `String.hashValue`
    /// is seeded per process, which moved the socket directory on every
    /// launch: the stale-socket unlink at start could never fire across
    /// launches, and crash-orphaned dirs accumulated in /tmp until reboot.
    private static func stableSuffix(_ s: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in s.utf8 { hash = (hash ^ UInt32(byte)) &* 0x0100_0193 }
        return String(format: "%08x", hash)
    }

    /// The bound socket lives at a short `/tmp` path (bind() caps sun_path at
    /// ~104 bytes, mirroring SentinelIPCClient); the pointer file, which has no
    /// length limit, sits in the app-support dir where the skill looks for it.
    private static func resolveSocketPaths() -> SocketPaths? {
        let uid = getuid()
        let bundleId = FileSystemUtils.bundleId
        let hash = stableSuffix(bundleId)
        let dir = "/tmp/phi-cdp-\(uid).\(hash)"
        let socket = (dir as NSString).appendingPathComponent("agent.sock")
        guard socket.utf8.count < 104 else {
            AppLogError("[AgentCDP] socket path too long: \(socket)")
            return nil
        }
        let pointer = (FileSystemUtils.applicationSupportDirctory() as NSString)
            .appendingPathComponent("CDPAgentSocket")
        return SocketPaths(socket: socket, pointer: pointer)
    }

    /// Creates the socket's parent directory as a 0700, self-owned directory,
    /// refusing to proceed if an existing one is owned by someone else (a
    /// squatting attempt on the predictable `/tmp` path).
    private static func prepareSocketDirectory(for socketPath: String) -> Bool {
        let dir = (socketPath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir, isDirectory: &isDir) {
            var st = stat()
            if stat(dir, &st) == 0, st.st_uid != getuid() {
                AppLogError("[AgentCDP] socket dir \(dir) owned by uid \(st.st_uid); refusing")
                return false
            }
            return isDir.boolValue
        }
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            AppLogError("[AgentCDP] mkdir \(dir) failed: \(error)")
            return false
        }
    }

    /// Best-effort sweep of crash-orphaned socket dirs — including the
    /// per-launch-suffixed ones older builds left behind, which a crash
    /// stranded in /tmp until reboot. A sibling dir whose socket no longer
    /// accepts is dead weight; a live one (the other Phi flavor's channel)
    /// is left alone.
    private static func sweepOrphanedSocketDirs(keeping ownDir: String) {
        let prefix = "phi-cdp-\(getuid())."
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: "/tmp") else { return }
        for entry in entries where entry.hasPrefix(prefix) {
            let dir = "/tmp/" + entry
            guard dir != ownDir else { continue }
            let sock = (dir as NSString).appendingPathComponent("agent.sock")
            guard !socketAccepts(sock) else { continue }
            try? fm.removeItem(atPath: dir)
        }
    }

    /// connect(2) probe: a live listener accepts immediately; a
    /// crash-orphaned socket file refuses in ~0 ms.
    private static func socketAccepts(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        guard fillSunPath(&addr, with: path) else { return false }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, len)
            }
        }
        return rc == 0
    }

    private static func fillSunPath(_ addr: inout sockaddr_un, with path: String) -> Bool {
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= capacity else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: pathBytes.count)
                }
            }
        }
        return true
    }

    private static func bind(fd: Int32, to path: String) -> Bool {
        var addr = sockaddr_un()
        guard fillSunPath(&addr, with: path) else { return false }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, len)
            }
        }
        if rc != 0 {
            AppLogError("[AgentCDP] bind() failed: \(String(cString: strerror(errno)))")
            return false
        }
        return true
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Writes a short 403 so the skill's HTTP discovery gets a clear status,
    /// then closes. The fd is blocking-drained best-effort; denial is rare.
    private static func denyAndClose(_ fd: Int32) {
        let body = "Phi Browser denied agent access.\n"
        let response = "HTTP/1.1 403 Forbidden\r\n"
            + "Content-Type: text/plain\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
            + body
        let bytes = Array(response.utf8)
        bytes.withUnsafeBytes { raw in
            _ = write(fd, raw.baseAddress, raw.count)
        }
        close(fd)
    }
}

extension Notification.Name {
    /// Posted when agent CDP access is switched on or off. The Settings toggle
    /// is no longer the only thing that flips it — approving a consent prompt
    /// does too — so the Developer pane has to hear about changes it didn't
    /// make, or it would sit there reading "off" while an agent drives.
    static let agentCDPAccessDidChange = Notification.Name("agentCDPAccessDidChange")
}
