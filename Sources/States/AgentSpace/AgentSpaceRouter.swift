// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Pure authorization rule for task-scoped operations. Kept separate from
/// manager lookup/keep-alive side effects so the cross-agent boundary has
/// focused unit coverage.
enum AgentTaskAccessPolicy {
    static func allows(
        taskOrigin: AgentTaskOrigin,
        taskPrincipalId: String?,
        callerOrigin: AgentTaskOrigin,
        callerPrincipalId: String?
    ) -> Bool {
        guard taskOrigin == callerOrigin else { return false }
        switch taskOrigin {
        case .phiAgent:
            return true
        case .cdp:
            guard let taskPrincipalId, !taskPrincipalId.isEmpty,
                  let callerPrincipalId, !callerPrincipalId.isEmpty else {
                return false
            }
            return taskPrincipalId == callerPrincipalId
        }
    }
}

/// Parses `agentSpace.*` extension messages and drives `AgentSpaceManager`.
/// Extension messages are delivered on the main thread, so the manager's
/// main-actor state is accessed via `MainActor.assumeIsolated`. Messages arrive both from the
/// Kensington extension and — with senderId "cdp" — from remote-debugging
/// clients through the PhiAgentSpace CDP domain.
enum AgentSpaceRouter {
    // These helpers are shared with the management handlers in
    // AgentSpaceRouter+Management.swift (internal, not private, for that
    // reason only — they are not meant as general-purpose API).
    static func json(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    static func origin(for context: ExtensionMessageContext) -> AgentTaskOrigin {
        context.senderId == "cdp" ? .cdp : .phiAgent
    }

    /// A caller may only operate on tasks of its own origin and, for external
    /// CDP tasks, its own app-issued logical driver principal. Thus separate
    /// approved agents cannot discover a taskId and operate each other's Space.
    /// Unknown tasks (and cross-origin ones) are treated identically — as if the
    /// task doesn't exist — so the boundary reveals nothing about the other
    /// driver's Spaces. Assumes the main actor (all callers are inside one).
    ///
    /// Doubles as the keep-alive heartbeat: every task-scoped message from the
    /// owning driver passes through here, so an authorized caller refreshes the
    /// task's expiry as a side effect — the driver is evidently alive. Explicit
    /// TTL control stays with `agentSpace.ping`. `touchKeepAlive: false` keeps
    /// the origin gate but skips the refresh, for traffic that proves the
    /// SESSION is alive without proving anyone is still driving (the session
    /// mirror's prose) — such traffic must not extend an idle Space's life.
    static func callerMayControl(
        taskId: String, context: ExtensionMessageContext,
        touchKeepAlive: Bool = true
    ) -> Bool {
        MainActor.assumeIsolated {
            guard let task = AgentSpaceManager.shared.task(forTaskId: taskId),
                  AgentTaskAccessPolicy.allows(
                    taskOrigin: task.origin,
                    taskPrincipalId: task.driverPrincipalId,
                    callerOrigin: origin(for: context),
                    callerPrincipalId: context.driverPrincipalId) else {
                return false
            }
            if touchKeepAlive {
                AgentSpaceManager.shared.touchKeepAlive(taskId: taskId)
            }
            return true
        }
    }

    /// `agentSpace.ping` — keep-alive heartbeat. Without it (and without any
    /// other control message) a driving task's Space auto-closes after
    /// `AgentSpaceManager.defaultKeepAliveTTL`. The optional `ttlSeconds`
    /// (clamped to `maxKeepAliveTTL`) buys a longer window — the skill pings
    /// with a large TTL when a round ends so the task survives the gap until
    /// its next round; while the user holds control the clock is paused.
    static func handlePing(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let taskId = obj["taskId"] as? String else { return invalid() }
        guard callerMayControl(taskId: taskId, context: context) else { return unknownTask() }
        if let ttl = obj["ttlSeconds"] as? Double {
            MainActor.assumeIsolated {
                AgentSpaceManager.shared.touchKeepAlive(taskId: taskId, ttlSeconds: ttl)
            }
        }
        // The default refresh already happened inside callerMayControl.
        return ok()
    }

    /// `agentSpace.create` — async: spawn the Space, then reply with ids.
    static func handleCreate(context: ExtensionMessageContext) {
        let requestId = context.requestId
        let taskOrigin = origin(for: context)
        MainActor.assumeIsolated {
            guard let obj = json(context.payload),
                  let taskId = obj["taskId"] as? String else {
                ExtensionMessaging.shared.sendError("invalid_payload", requestId: requestId)
                return
            }
            if taskOrigin == .cdp {
                guard let principalId = context.driverPrincipalId,
                      !principalId.isEmpty else {
                    ExtensionMessaging.shared.sendError(
                        "missing_driver_principal", requestId: requestId)
                    return
                }
            }
            let profileName =
                (obj["profileId"] as? String)
                ?? (obj["profileName"] as? String)
                ?? ""
            let persistent = obj["persistent"] as? Bool ?? false
            // Per-profile agent-Space permission (Settings ▸ Developer ▸ Agent
            // permissions): refuse creation in a profile the user disallows.
            // An empty request resolves to the first allowed profile, so the
            // agent's default never lands on a blocked one; an explicit request
            // for a blocked profile is refused. The resolved profileId is
            // passed on so create binds exactly what the permission approved.
            let agentName = context.agentName
            let proceedCreate: @MainActor (String) -> Void = { resolvedProfileName in
                AgentSpaceManager.shared.createAgentSpace(
                    taskId: taskId,
                    profileName: resolvedProfileName,
                    origin: taskOrigin,
                    persistent: persistent,
                    agentName: agentName,
                    driverPrincipalId: context.driverPrincipalId
                ) { spaceId, windowId in
                    var replyObject: [String: Any]?
                    if let spaceId, let windowId {
                        // A create normally yields an agent-owned Space, but a
                        // restart re-adoption returns the task as it stands —
                        // possibly mid-handoff with the USER holding control —
                        // so the reply carries the authoritative owner.
                        let owner = AgentSpaceManager.shared
                            .task(forTaskId: taskId)?.ownership == .user ? "user" : "agent"
                        replyObject = ["ok": true, "spaceId": spaceId,
                                       "windowId": windowId, "ownership": owner]
                    }
                    if let replyObject,
                       let data = try? JSONSerialization.data(withJSONObject: replyObject),
                       let reply = String(data: data, encoding: .utf8) {
                        ExtensionMessaging.shared.sendResponse(reply, requestId: requestId)
                    } else {
                        ExtensionMessaging.shared.sendResponse(
                            "{\"ok\":false,\"error\":\"create_failed\"}",
                            requestId: requestId)
                    }
                }
            }

            switch AgentSpaceManager.shared.resolveAgentCreateProfile(profileName: profileName) {
            case .allowed(let profile):
                proceedCreate(profile.profileId)
            case .blocked:
                ExtensionMessaging.shared.sendResponse(
                    "{\"ok\":false,\"error\":\"profile_not_agent_allowed\"}",
                    requestId: requestId)
            case .noMatch:
                // Unknown profile — let createAgentSpace surface its own failure
                // (persistent re-bind may still match by taskId).
                proceedCreate(profileName)
            case .needsTemporary:
                // The user left the agent no usable profile — create/reuse a
                // dedicated one and bind the Space to it.
                AgentSpaceManager.shared.ensureAgentFallbackProfile { profileId in
                    MainActor.assumeIsolated {
                        guard let profileId else {
                            ExtensionMessaging.shared.sendResponse(
                                "{\"ok\":false,\"error\":\"create_failed\"}",
                                requestId: requestId)
                            return
                        }
                        proceedCreate(profileId)
                    }
                }
            }
        }
    }

    /// `agentSpace.listProfiles` — enumerate browser profiles so a client can
    /// pick one for `agentSpace.create`; a stateless CDP client has no other
    /// discovery path. Informational, so not origin-scoped.
    static func handleListProfiles(context: ExtensionMessageContext) -> String? {
        let profiles = MainActor.assumeIsolated { () -> [[String: Any]] in
            // Same refresh-before-read as createAgentSpace: a headless CDP
            // call can't rely on profile UI having populated the cache.
            ProfileManager.shared.refresh()
            return ProfileManager.shared.profiles.map {
                [
                    "profileId": $0.profileId,
                    "displayName": $0.displayName,
                    // Whether the agent may create a Space in this profile
                    // (Settings ▸ Developer ▸ Agent permissions). A create
                    // targeting a profile with false is refused.
                    "agentSpacesAllowed":
                        PhiPreferences.AgentSpaces.isProfileAgentSpaceAllowed($0.profileId),
                ]
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["profiles": profiles]),
              let reply = String(data: data, encoding: .utf8) else {
            return "{\"profiles\":[]}"
        }
        return reply
    }

    /// `agentSpace.list` — enumerate live tasks so a stateless client (the CDP
    /// skill re-connects every round) can rediscover its Space by taskId.
    static func handleList(context: ExtensionMessageContext) -> String? {
        let caller = origin(for: context)
        let tasks = MainActor.assumeIsolated {
            AgentSpaceManager.shared.tasksBySpaceId.values
                .filter {
                    AgentTaskAccessPolicy.allows(
                        taskOrigin: $0.origin,
                        taskPrincipalId: $0.driverPrincipalId,
                        callerOrigin: caller,
                        callerPrincipalId: context.driverPrincipalId)
                }
                .map { task -> [String: Any] in
                let status: String = {
                    switch task.status {
                    case .starting: return "starting"
                    case .running: return "running"
                    case .idle: return "idle"
                    case .completed: return "completed"
                    case .failed: return "failed"
                    }
                }()
                // Remaining keep-alive so a status probe can report it. This
                // handler is NOT a control message (no callerMayControl), so
                // reading the clock never refreshes it. null while the user
                // holds control — the sweep pauses, so a run-down value would
                // read as urgency that isn't there — or when no deadline
                // applies.
                let keepAliveRemaining: Any = {
                    guard task.ownership == .agent,
                          task.keepAliveDeadline != .distantFuture else { return NSNull() }
                    return max(0, Int(task.keepAliveDeadline.timeIntervalSinceNow.rounded()))
                }()
                return [
                    "taskId": task.taskId,
                    "spaceId": task.spaceId,
                    "windowId": task.windowId,
                    "ownership": task.ownership == .agent ? "agent" : "user",
                    "status": status,
                    "caption": task.statusCaption,
                    "keepAliveRemainingSeconds": keepAliveRemaining,
                    "persistent": task.persistent,
                    // Undrained console commands (see `agentSpace.readUserMessages`)
                    // so passive status reads surface pending user input for free.
                    "pendingUserMessages":
                        AgentSpaceManager.shared.pendingUserMessageCount(taskId: task.taskId),
                    // The resolved driving-agent identity that badges the Space.
                    "agentName": task.agentName,
                ]
            }
        }
        // Top-level because it is app state, not task state: whether the Agent
        // Transcript console is open (View ▸ Agent Transcript, or a pip's
        // context menu) — the user's existing toggle for the transcript. Every
        // skill round lists tasks before binding, so this is the flag's live
        // delivery path: the skill spawns its session-mirror daemon only while
        // this reads true, sampled at each round start.
        let transcriptOpen = MainActor.assumeIsolated {
            AgentTranscriptPanelController.shared.isVisible
        }
        let reply: [String: Any] = [
            "tasks": tasks,
            "transcriptMirror": transcriptOpen,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: reply),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"tasks\":[]}"
        }
        return text
    }

    static func handleSetState(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let taskId = obj["taskId"] as? String else { return invalid() }
        guard callerMayControl(taskId: taskId, context: context) else { return unknownTask() }
        // Both fields are optional and independent: a caption-only call must not
        // wipe the run state, and a run-state-only call must not wipe the caption.
        let caption = obj["caption"] as? String
        let runState = obj["state"] as? String
        MainActor.assumeIsolated {
            if let caption {
                AgentSpaceManager.shared.setStatusCaption(taskId: taskId, caption: caption)
            }
            switch runState {
            case "running": AgentSpaceManager.shared.setRunState(taskId: taskId, running: true)
            case "idle": AgentSpaceManager.shared.setRunState(taskId: taskId, running: false)
            default: break
            }
        }
        return ok()
    }

    static func handleCursor(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let taskId = obj["taskId"] as? String,
              let x = obj["x"] as? Double,
              let y = obj["y"] as? Double else { return invalid() }
        guard callerMayControl(taskId: taskId, context: context) else { return unknownTask() }
        // tabId is optional: CDP clients don't know Phi tab ids; 0 means "the
        // currently displayed tab" to the overlay mounter.
        let tabId = obj["tabId"] as? Int ?? 0
        MainActor.assumeIsolated {
            AgentSpaceManager.shared.setCursor(
                taskId: taskId, tabId: tabId, point: CGPoint(x: x, y: y))
        }
        return ok()
    }

    /// `agentSpace.effect` — a transient input-mirror animation (click ripple,
    /// typing pulse, scroll hint) for the overlay. Coordinates arrive in the
    /// same widget space as `agentSpace.cursor`; all fields beyond `kind` are
    /// optional (a point-less effect anchors on the task's cursor).
    static func handleEffect(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let taskId = obj["taskId"] as? String,
              let kindRaw = obj["kind"] as? String,
              let kind = AgentEffect.Kind(rawValue: kindRaw) else { return invalid() }
        guard callerMayControl(taskId: taskId, context: context) else { return unknownTask() }
        var point: CGPoint?
        if let x = obj["x"] as? Double, let y = obj["y"] as? Double {
            point = CGPoint(x: x, y: y)
        }
        var size: CGSize?
        if let w = obj["w"] as? Double, let h = obj["h"] as? Double {
            size = CGSize(width: w, height: h)
        }
        let dy = (obj["dy"] as? Double).map { CGFloat($0) }
        MainActor.assumeIsolated {
            AgentSpaceManager.shared.showEffect(
                taskId: taskId, kind: kind, point: point, size: size, dy: dy)
        }
        return ok()
    }

    /// `agentSpace.log` — lines for the task's live transcript console, one
    /// at top level (`text`) or batched (`entries`, oldest first — the session
    /// forwarder flushes each batch as ONE call so delivery is all-or-nothing
    /// and a mid-batch failure can't duplicate an already-delivered prefix).
    /// Fire-and-forget from the driver, like `agentSpace.effect`: cosmetic,
    /// never load-bearing for the primitive that emitted it. The origin gate
    /// also means one driver cannot spoof lines into another's console.
    /// `touch: false` marks mirror traffic that must not refresh keep-alive
    /// (see `callerMayControl`).
    static func handleLog(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let taskId = obj["taskId"] as? String else { return invalid() }
        let items: [[String: Any]]
        if let batch = obj["entries"] as? [[String: Any]] {
            items = Array(batch.prefix(Self.maxLogBatchEntries))
        } else if obj["text"] is String {
            items = [obj]
        } else {
            return invalid()
        }
        let touch = obj["touch"] as? Bool ?? true
        guard callerMayControl(taskId: taskId, context: context,
                               touchKeepAlive: touch) else { return unknownTask() }
        MainActor.assumeIsolated {
            for item in items {
                guard let text = item["text"] as? String else { continue }
                // Mirror turn edges drive a live tail row; they replace one
                // another and deliberately never enter transcript history.
                if item["kind"] as? String == "activity" {
                    if item["agent"] as? String == "codex",
                       let activity = CodexTranscriptActivity(rawValue: text) {
                        AgentTranscriptStore.shared.setCodexActivity(
                            taskId: taskId, activity: activity)
                    }
                    if item["agent"] as? String == "claude",
                       let activity = ClaudeTranscriptActivity(payloadText: text) {
                        AgentTranscriptStore.shared.setClaudeActivity(
                            taskId: taskId, activity: activity)
                    }
                    // Activity is a control record reserved for the mirrored
                    // CLIs' transient tail rows. Drop the kind for every
                    // other origin instead of degrading it into a visible
                    // action line.
                    continue
                }
                var kind = AgentTranscriptEntry.Kind(rawValue: item["kind"] as? String ?? "")
                    ?? .action
                // `status` and `round` are app lifecycle lines (ownership
                // flips, round edges) — reserved so a driver cannot forge
                // "You took control"-style entries in its console.
                if kind == .status || kind == .round { kind = .action }
                let agent = item["agent"] as? String
                // Pairing metadata is reserved for Pi tool cards. Other
                // agents retain append-only transcript semantics even if a
                // caller sends similarly named fields.
                let isPiTool = agent == "pi" && kind == .tool
                AgentSpaceManager.shared.appendTranscript(
                    taskId: taskId, kind: kind, text: text,
                    detail: item["detail"] as? String,
                    agent: agent,
                    piToolCallId: isPiTool ? item["sourceId"] as? String : nil,
                    piToolState: isPiTool
                        ? (item["toolState"] as? String).flatMap(
                            PiTranscriptToolState.init(rawValue:))
                        : nil,
                    timestamp: Self.clampedLogTimestamp(item["ts"] as? Double))
            }
        }
        return ok()
    }

    /// Ceiling well above the forwarder's per-run cap; a runaway batch is
    /// truncated, not rejected (the console is cosmetic).
    private static let maxLogBatchEntries = 200

    /// Optional source timestamp (epoch ms), so a mirrored session line
    /// forwarded after the fact sorts by when it was really authored. Trusted
    /// for ORDER, not range: an absurd epoch would pin the line to the top or
    /// bottom of the time-sorted feed forever, so clamp to a sane window
    /// (a day of backfill behind, a couple of minutes of clock skew ahead).
    private static func clampedLogTimestamp(_ epochMs: Double?) -> Date {
        guard let epochMs else { return Date() }
        let now = Date()
        let ts = Date(timeIntervalSince1970: epochMs / 1000)
        return min(max(ts, now.addingTimeInterval(-86400)), now.addingTimeInterval(120))
    }

    /// `agentSpace.readUserMessages` — hand the driver the commands the user
    /// typed into the console since the last drain, emptying the queue. The
    /// skill drains at round boundaries; `agentSpace.userMessage` broadcasts
    /// wake a live round, but this queue is what guarantees delivery.
    static func handleReadUserMessages(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let taskId = obj["taskId"] as? String else { return invalid() }
        guard callerMayControl(taskId: taskId, context: context) else { return unknownTask() }
        let messages = MainActor.assumeIsolated {
            AgentSpaceManager.shared.drainUserMessages(taskId: taskId).map {
                [
                    "id": $0.id.uuidString,
                    "text": $0.text,
                    "ts": Int($0.ts.timeIntervalSince1970 * 1000),
                ] as [String: Any]
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["messages": messages]),
              let reply = String(data: data, encoding: .utf8) else {
            return "{\"messages\":[]}"
        }
        return reply
    }

    static func handleMarkError(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let taskId = obj["taskId"] as? String else { return invalid() }
        guard callerMayControl(taskId: taskId, context: context) else { return unknownTask() }
        let message = obj["message"] as? String ?? "error"
        MainActor.assumeIsolated {
            AgentSpaceManager.shared.markError(taskId: taskId, message: message)
        }
        return ok()
    }

    static func handleComplete(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let taskId = obj["taskId"] as? String else { return invalid() }
        guard callerMayControl(taskId: taskId, context: context) else { return unknownTask() }
        let status = obj["status"] as? String ?? "success"
        let keep = obj["keep"] as? Bool ?? true
        let message = obj["message"] as? String
        MainActor.assumeIsolated {
            AgentSpaceManager.shared.taskDidComplete(
                taskId: taskId,
                success: status == "success",
                keep: keep,
                message: message)
        }
        return ok()
    }

    /// `agentSpace.panelSize` — the size a page renders at in the user's
    /// visible window: the web-content panel, sidebar/header excluded. A CDP
    /// client sizes its hidden agent window's emulated viewport with this so
    /// the agent lays pages out exactly as the user's window would — the
    /// hidden window's own view size reads 0×0 over CDP, and measuring user
    /// tabs is unreliable (native-NTP shells). Informational, so not
    /// origin-scoped — same class as `agentSpace.listProfiles`.
    static func handlePanelSize(context: ExtensionMessageContext) -> String? {
        let size = MainActor.assumeIsolated { () -> CGSize? in
            let slot = SpaceManager.shared.keySlot ?? SpaceManager.shared.slots.first
            return slot?.visibleController?.mainSplitViewController
                .webContentContainerViewController.currentWebPanelSize
        }
        guard let size, size.width > 0, size.height > 0 else {
            return "{\"ok\":false,\"error\":\"no_visible_panel\"}"
        }
        return "{\"width\":\(Int(size.width)),\"height\":\(Int(size.height))}"
    }

    static func handleGetOwnership(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let taskId = obj["taskId"] as? String else { return invalid() }
        guard callerMayControl(taskId: taskId, context: context) else {
            return "{\"owner\":\"none\"}"
        }
        let owner = MainActor.assumeIsolated { () -> String in
            switch AgentSpaceManager.shared.ownership(forTaskId: taskId) {
            case .user: return "user"
            case .agent: return "agent"
            case nil: return "none"
            }
        }
        return "{\"owner\":\"\(owner)\"}"
    }

    /// `agentSpace.handoff` — the agent gives control to the user (login,
    /// captcha, manual confirmation). Same transition as a user interrupt.
    static func handleHandoff(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let taskId = obj["taskId"] as? String else { return invalid() }
        guard callerMayControl(taskId: taskId, context: context) else { return unknownTask() }
        // What the agent needs the user to do (login, captcha, …); surfaced in
        // the handoff prompt.
        let message = obj["message"] as? String
        let handled = MainActor.assumeIsolated {
            AgentSpaceManager.shared.interruptByAgentRequest(taskId: taskId, message: message)
        }
        return handled ? ok() : "{\"ok\":false,\"error\":\"unknown_task\"}"
    }

    /// `agentSpace.takeover` — the agent resumes control after the user
    /// explicitly confirmed. Policy (never seize control without the user's
    /// go-ahead) is enforced by the client, mirroring ego's takeover.
    static func handleTakeover(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let taskId = obj["taskId"] as? String else { return invalid() }
        guard callerMayControl(taskId: taskId, context: context) else { return unknownTask() }
        let handled = MainActor.assumeIsolated {
            AgentSpaceManager.shared.resumeAgentControl(taskId: taskId)
        }
        return handled ? ok() : "{\"ok\":false,\"error\":\"unknown_task\"}"
    }

    /// `agentSpace.openTab` — open a URL as a background tab in the task's
    /// window. CDP clients use this instead of Target.createTarget, which has
    /// no notion of a target window.
    static func handleOpenTab(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let taskId = obj["taskId"] as? String,
              let url = obj["url"] as? String, !url.isEmpty else { return invalid() }
        guard callerMayControl(taskId: taskId, context: context) else { return unknownTask() }
        let windowId = MainActor.assumeIsolated {
            AgentSpaceManager.shared.task(forTaskId: taskId)?.windowId
        }
        guard let windowId, windowId != 0 else {
            return "{\"ok\":false,\"error\":\"unknown_task\"}"
        }
        DispatchQueue.main.async {
            ChromiumLauncher.sharedInstance().bridge?
                .createNewTab(withUrl: url,
                              windowId: Int64(windowId),
                              customGuid: nil,
                              focusAfterCreate: false)
        }
        return ok()
    }

    static func ok() -> String { "{\"ok\":true}" }
    static func invalid() -> String { "{\"ok\":false,\"error\":\"invalid_payload\"}" }
    static func unknownTask() -> String { "{\"ok\":false,\"error\":\"unknown_task\"}" }
}
