// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// The shadow-window slice of the `agentSpace.*` message surface: opening and
/// driving invisible background windows (see AgentSpaceManager+Shadow.swift).
///
/// Every route here registers through `registerUserSpaceManaged`, so the whole
/// feature is behind Settings ▸ Developer ▸ Agent control ("let agents operate
/// your Spaces"). That gate, not a shadow-specific one, is deliberate: an
/// agent Space announces itself with a pip the user can watch and take over,
/// a shadow window announces nothing. The permission is on by default, so
/// agents can open shadow windows unless the user turns it off; a user who has
/// denied agents reach beyond their own visible Spaces must not get invisible
/// ones. The setting's description is where the app tells users these windows
/// exist, so keep it in step with this surface.
///
/// Conventions match the rest of the router: messages arrive on the main
/// thread (main-actor state via `MainActor.assumeIsolated`), replies are JSON
/// with the `ok`/`error` shape, and task-scoped routes are origin- and
/// principal-guarded so drivers cannot reach each other's windows.
extension AgentSpaceRouter {
    /// `agentSpace.shadow.create` — async: open the window, then reply with its
    /// id. Re-binding to an existing shadow window of the same taskId is a
    /// success, not a conflict, so a driver's next round reattaches.
    static func handleShadowCreate(context: ExtensionMessageContext) {
        let requestId = context.requestId
        let taskOrigin = origin(for: context)
        MainActor.assumeIsolated {
            guard let obj = json(context.payload),
                  let taskId = obj["taskId"] as? String, !taskId.isEmpty else {
                ExtensionMessaging.shared.sendError("invalid_payload", requestId: requestId)
                return
            }
            if taskOrigin == .cdp {
                guard let principalId = context.driverPrincipalId, !principalId.isEmpty else {
                    ExtensionMessaging.shared.sendError(
                        "missing_driver_principal", requestId: requestId)
                    return
                }
            }
            let requestedProfile =
                (obj["profileId"] as? String) ?? (obj["profileName"] as? String) ?? ""
            // The `incognito` echo in the success reply is deliberate: a driver
            // that requested incognito against an app build that predates it
            // sees the field missing and can refuse to proceed, instead of
            // silently browsing in the regular profile.
            let incognito = (obj["incognito"] as? Bool) ?? false
            let reply: @MainActor (Int?, String?) -> Void = { windowId, error in
                guard let windowId else {
                    ExtensionMessaging.shared.sendResponse(
                        failure(error ?? "create_failed"), requestId: requestId)
                    return
                }
                ExtensionMessaging.shared.sendResponse(
                    encode(["ok": true, "windowId": windowId, "incognito": incognito]),
                    requestId: requestId)
            }
            let proceed: @MainActor (String) -> Void = { profileId in
                AgentSpaceManager.shared.createShadowWindow(
                    taskId: taskId,
                    profileId: profileId,
                    incognito: incognito,
                    origin: taskOrigin,
                    driverPrincipalId: context.driverPrincipalId,
                    completion: { windowId, error in
                        MainActor.assumeIsolated { reply(windowId, error) }
                    })
            }

            // Same profile resolution and per-profile permission as
            // `agentSpace.create`: a profile the user blocked for agent Spaces
            // is blocked here too.
            switch AgentSpaceManager.shared.resolveAgentCreateProfile(profileName: requestedProfile) {
            case .allowed(let profile):
                proceed(profile.profileId)
            case .blocked:
                ExtensionMessaging.shared.sendResponse(
                    failure("profile_not_agent_allowed"), requestId: requestId)
            case .noMatch:
                ExtensionMessaging.shared.sendResponse(
                    failure("unknown_profile"), requestId: requestId)
            case .needsTemporary:
                AgentSpaceManager.shared.ensureAgentFallbackProfile { profileId in
                    MainActor.assumeIsolated {
                        guard let profileId else {
                            ExtensionMessaging.shared.sendResponse(
                                failure("create_failed"), requestId: requestId)
                            return
                        }
                        proceed(profileId)
                    }
                }
            }
        }
    }

    /// `agentSpace.shadow.list` — the caller's own shadow windows. Scoped to
    /// the caller's origin and principal, so it doubles as the discovery path
    /// for a driver that restarted and lost its taskId → windowId mapping.
    static func handleShadowList(context: ExtensionMessageContext) -> String? {
        MainActor.assumeIsolated {
            let shadows = AgentSpaceManager.shared.shadowWindows(
                forOrigin: origin(for: context),
                principalId: context.driverPrincipalId)
            let rows: [[String: Any]] = shadows.map {
                ["taskId": $0.taskId,
                 "windowId": $0.windowId,
                 "profileId": $0.profileId,
                 "incognito": $0.incognito,
                 "createdAt": Int($0.createdAt.timeIntervalSince1970 * 1000)]
            }
            return encode(["ok": true, "shadows": rows])
        }
    }

    /// `agentSpace.shadow.openTab` — open a URL as a new tab in the task's
    /// shadow window. The driver then finds it over CDP by window id.
    static func handleShadowOpenTab(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let taskId = obj["taskId"] as? String,
              let url = obj["url"] as? String, !url.isEmpty else { return invalid() }
        return MainActor.assumeIsolated {
            guard callerMayControlShadow(taskId: taskId, context: context) else {
                return unknownTask()
            }
            guard AgentSpaceManager.shared.openShadowTab(taskId: taskId, url: url) else {
                return unknownTask()
            }
            return ok()
        }
    }

    /// `agentSpace.shadow.ping` — keep-alive heartbeat, mirroring
    /// `agentSpace.ping`. Without it an abandoned shadow window is reclaimed
    /// after `AgentSpaceManager.defaultKeepAliveTTL`.
    static func handleShadowPing(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let taskId = obj["taskId"] as? String else { return invalid() }
        return MainActor.assumeIsolated {
            guard callerMayControlShadow(taskId: taskId, context: context) else {
                return unknownTask()
            }
            if let ttl = obj["ttlSeconds"] as? Double {
                AgentSpaceManager.shared.touchShadowKeepAlive(taskId: taskId, ttlSeconds: ttl)
            }
            return ok()
        }
    }

    /// `agentSpace.shadow.close` — tear the window down. A driver that finishes
    /// should call this rather than leaning on the keep-alive sweep: the window
    /// is invisible, so the sweep is a backstop, not a lifecycle.
    static func handleShadowClose(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let taskId = obj["taskId"] as? String else { return invalid() }
        return MainActor.assumeIsolated {
            guard callerMayControlShadow(taskId: taskId, context: context,
                                         touchKeepAlive: false) else {
                return unknownTask()
            }
            AgentSpaceManager.shared.closeShadowWindow(taskId: taskId, reason: "driver closed")
            return ok()
        }
    }

    /// The shadow counterpart of `callerMayControl`: same origin + principal
    /// boundary, same keep-alive-as-a-side-effect, over the shadow registry.
    /// Unknown and cross-driver taskIds are indistinguishable to the caller.
    @MainActor
    private static func callerMayControlShadow(
        taskId: String, context: ExtensionMessageContext, touchKeepAlive: Bool = true
    ) -> Bool {
        guard let shadow = AgentSpaceManager.shared.shadowWindow(forTaskId: taskId),
              AgentTaskAccessPolicy.allows(
                taskOrigin: shadow.origin,
                taskPrincipalId: shadow.driverPrincipalId,
                callerOrigin: origin(for: context),
                callerPrincipalId: context.driverPrincipalId) else {
            return false
        }
        if touchKeepAlive {
            AgentSpaceManager.shared.touchShadowKeepAlive(taskId: taskId)
        }
        return true
    }
}
