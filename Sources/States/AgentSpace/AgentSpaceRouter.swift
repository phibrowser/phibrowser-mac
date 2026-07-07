// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Parses `agentSpace.*` extension messages and drives `AgentSpaceManager`.
/// Extension messages are delivered on the main thread (same assumption the
/// `toggleAgentAnimation` handler relies on), so the manager's main-actor state
/// is accessed via `MainActor.assumeIsolated`. Messages arrive both from the
/// Kensington extension and — with senderId "cdp" — from remote-debugging
/// clients through the PhiAgentSpace CDP domain.
enum AgentSpaceRouter {
    private static func json(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func origin(for context: ExtensionMessageContext) -> AgentTaskOrigin {
        context.senderId == "cdp" ? .cdp : .phiAgent
    }

    /// A caller may only operate on tasks of its own origin: the CDP tunnel must
    /// not drive phi-agent Spaces, and phi-agent must not drive CDP Spaces.
    /// Unknown tasks (and cross-origin ones) are treated identically — as if the
    /// task doesn't exist — so the boundary reveals nothing about the other
    /// driver's Spaces. Assumes the main actor (all callers are inside one).
    private static func callerMayControl(
        taskId: String, context: ExtensionMessageContext
    ) -> Bool {
        MainActor.assumeIsolated {
            AgentSpaceManager.shared.origin(forTaskId: taskId) == origin(for: context)
        }
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
            let profileName =
                (obj["profileId"] as? String)
                ?? (obj["profileName"] as? String)
                ?? ""
            AgentSpaceManager.shared.createAgentSpace(
                taskId: taskId,
                profileName: profileName,
                origin: taskOrigin
            ) { spaceId, windowId in
                var replyObject: [String: Any]?
                if let spaceId, let windowId {
                    replyObject = ["ok": true, "spaceId": spaceId, "windowId": windowId]
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
                ["profileId": $0.profileId, "displayName": $0.displayName]
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
                .filter { $0.origin == caller }
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
                return [
                    "taskId": task.taskId,
                    "spaceId": task.spaceId,
                    "windowId": task.windowId,
                    "ownership": task.ownership == .agent ? "agent" : "user",
                    "status": status,
                    "caption": task.statusCaption,
                ]
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["tasks": tasks]),
              let reply = String(data: data, encoding: .utf8) else {
            return "{\"tasks\":[]}"
        }
        return reply
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

    private static func ok() -> String { "{\"ok\":true}" }
    private static func invalid() -> String { "{\"ok\":false,\"error\":\"invalid_payload\"}" }
    private static func unknownTask() -> String { "{\"ok\":false,\"error\":\"unknown_task\"}" }
}
