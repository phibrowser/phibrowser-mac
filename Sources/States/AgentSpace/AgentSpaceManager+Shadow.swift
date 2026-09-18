// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation
import PostHog

/// A shadow window opened for an agent task: a Chromium `is_shadow` browser —
/// TYPE_NORMAL on a real profile, but alpha 0, off-screen, out of Mission
/// Control and omitted from session restore (see Browser::is_shadow()).
///
/// It is deliberately NOT a Space. There is no pip, no transcript, no cursor
/// mirroring and no ownership handoff, because there is nothing for the user
/// to watch or take over — the window has no pixels on screen. That is the
/// whole trade: an agent Space is co-working, a shadow window is background
/// execution, and the user's only controls over it are the permission that
/// allowed it and the keep-alive clock that reclaims it.
struct ShadowWindow {
    let taskId: String
    /// Chromium `session_id().id()` — the same integer `Browser.getWindowForTarget`
    /// reports over CDP, so a driver can match its targets to this window.
    let windowId: Int
    let profileId: String
    /// True when the window browses in a unique off-the-record profile derived
    /// from `profileId` (fresh session, destroyed with the window) instead of
    /// the profile itself. Fixed at creation: a taskId cannot flip between
    /// incognito and regular across re-binds.
    let incognito: Bool
    let origin: AgentTaskOrigin
    let driverPrincipalId: String?
    let createdAt: Date
    var keepAliveDeadline: Date
}

@MainActor
extension AgentSpaceManager {
    /// Seeded into every new shadow window so the driver always has a target to
    /// attach to. `about:blank` rather than the NTP: a shadow window is never
    /// looked at, and the NTP is a native view whose WebContents would only
    /// confuse a driver's first `observe()`.
    static let shadowSeedURL = "about:blank"

    // MARK: - Lifecycle

    /// Opens (or re-binds to) the shadow window bound to `taskId`.
    ///
    /// Re-binding is by taskId within the caller's own origin+principal, the
    /// same boundary `callerMayControl` draws for Spaces: a second driver
    /// asking for someone else's taskId is refused rather than handed the
    /// window. Profile resolution and the per-profile agent permission are
    /// shared with `createAgentSpace` — a profile the user blocked for agent
    /// Spaces is blocked for shadow windows too, and more so.
    ///
    /// `completion` receives the window id, or nil and a wire error reason
    /// when the window could not be created (profile unknown or failed to
    /// load, Chromium refused, incognito-ness conflicts with an existing
    /// window of the same taskId).
    func createShadowWindow(
        taskId: String,
        profileId: String,
        incognito: Bool,
        origin: AgentTaskOrigin,
        driverPrincipalId: String?,
        completion: @escaping (_ windowId: Int?, _ error: String?) -> Void
    ) {
        if origin == .cdp, driverPrincipalId?.isEmpty != false {
            AppLogWarn("[ShadowWindow] createShadowWindow: CDP task has no driver principal")
            completion(nil, "create_failed")
            return
        }
        if let existing = shadowWindowsByTaskId[taskId] {
            guard AgentTaskAccessPolicy.allows(
                taskOrigin: existing.origin,
                taskPrincipalId: existing.driverPrincipalId,
                callerOrigin: origin,
                callerPrincipalId: driverPrincipalId
            ) else {
                AppLogWarn("[ShadowWindow] createShadowWindow: taskId \(taskId) belongs to another driver")
                completion(nil, "create_failed")
                return
            }
            // windowId 0 is the in-flight placeholder below: a spawn for this
            // taskId is between the profile load and Browser::Create. Refuse
            // rather than let a re-entrant create open a second window that
            // nothing would ever close.
            guard existing.windowId != 0 else {
                AppLogWarn("[ShadowWindow] createShadowWindow: \(taskId) spawn already in flight")
                completion(nil, "create_failed")
                return
            }
            // Re-binding must not silently change what the driver believes it
            // is browsing in: a taskId's incognito-ness is fixed at creation.
            guard existing.incognito == incognito else {
                AppLogWarn("[ShadowWindow] createShadowWindow: \(taskId) exists with incognito=\(existing.incognito), refusing incognito=\(incognito) re-bind")
                completion(nil, "shadow_incognito_mismatch")
                return
            }
            touchShadowKeepAlive(taskId: taskId)
            completion(existing.windowId, nil)
            return
        }
        // A taskId is one agent job. Letting the same id name both a Space and
        // a shadow window would make every task-scoped route ambiguous.
        guard task(forTaskId: taskId) == nil else {
            AppLogWarn("[ShadowWindow] createShadowWindow: taskId \(taskId) is already an agent Space")
            completion(nil, "create_failed")
            return
        }
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(nil, "create_failed")
            return
        }
        // Claim the taskId before the async profile load, the way
        // `createAgentSpace` records its task up front: windowId 0 marks the
        // spawn as in flight so a second create for the same id is refused
        // instead of opening a duplicate invisible window.
        shadowWindowsByTaskId[taskId] = ShadowWindow(
            taskId: taskId,
            windowId: 0,
            profileId: profileId,
            incognito: incognito,
            origin: origin,
            driverPrincipalId: driverPrincipalId,
            createdAt: Date(),
            keepAliveDeadline: origin == .cdp
                ? Date().addingTimeInterval(Self.defaultKeepAliveTTL)
                : .distantFuture
        )
        ensureKeepAliveSweep()
        // Chromium resolves the profile strictly (no last-used fallback), so it
        // must be in memory before the window is created. For an incognito
        // window this loads the PARENT profile — Chromium derives the unique
        // OTR from it at create time.
        bridge.ensureProfileLoaded(profileId) { [weak self] success in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { completion(nil, "create_failed"); return }
                    guard success,
                          let bridge = ChromiumLauncher.sharedInstance().bridge else {
                        AppLogWarn("[ShadowWindow] ensureProfileLoaded failed for \(profileId)")
                        self.shadowWindowsByTaskId.removeValue(forKey: taskId)
                        completion(nil, "create_failed")
                        return
                    }
                    self.spawnShadowWindow(
                        taskId: taskId, profileId: profileId, incognito: incognito,
                        origin: origin, driverPrincipalId: driverPrincipalId,
                        bridge: bridge, completion: completion)
                }
            }
        }
    }

    private func spawnShadowWindow(
        taskId: String,
        profileId: String,
        incognito: Bool,
        origin: AgentTaskOrigin,
        driverPrincipalId: String?,
        bridge: PhiChromiumBridgeProtocol,
        completion: @escaping (_ windowId: Int?, _ error: String?) -> Void
    ) {
        // `hidden: true` skips Chromium's post-create Show(). Shadow windows
        // are hidden by the bridge anyway (alpha 0, off-screen), but the
        // parameter also keeps this spawn out of the slot-reveal path, which
        // is the half that assumes a Space.
        let windowType: ChromiumBrowserType = incognito ? .shadowIncognito : .shadow
        guard let dict = bridge.createBrowser(withWindowType: windowType,
                                              profileId: profileId,
                                              hidden: true),
              let windowIdNumber = dict["windowId"] as? NSNumber else {
            AppLogWarn("[ShadowWindow] createBrowserWithWindowType(\(incognito ? ".shadowIncognito" : ".shadow")) returned no window")
            shadowWindowsByTaskId.removeValue(forKey: taskId)
            completion(nil, "create_failed")
            return
        }
        let windowId = windowIdNumber.intValue
        // Replaces the in-flight placeholder claimed by createShadowWindow.
        shadowWindowsByTaskId[taskId] = ShadowWindow(
            taskId: taskId,
            windowId: windowId,
            profileId: profileId,
            incognito: incognito,
            origin: origin,
            driverPrincipalId: driverPrincipalId,
            createdAt: Date(),
            keepAliveDeadline: origin == .cdp
                ? Date().addingTimeInterval(Self.defaultKeepAliveTTL)
                : .distantFuture
        )
        // A freshly created Browser has no tabs, and nothing else seeds one:
        // session restore is suppressed for this call. Without a tab the
        // window has no CDP target to attach to.
        bridge.createNewTab(withUrl: Self.shadowSeedURL,
                            windowId: Int64(windowId),
                            customGuid: nil,
                            focusAfterCreate: false)
        AppLogInfo("[ShadowWindow] opened \(taskId) — windowId=\(windowId), profile=\(profileId), incognito=\(incognito)")
        PostHogSDK.shared.capture("agent_shadow_window_opened", properties: [
            "origin": origin == .cdp ? "cdp" : "phi_agent",
            "incognito": incognito,
        ])
        completion(windowId, nil)
    }

    /// Opens a tab in the task's shadow window. Never focuses: focusing an
    /// invisible window is meaningless, and the driver picks its target over
    /// CDP anyway.
    func openShadowTab(taskId: String, url: String) -> Bool {
        guard let shadow = shadowWindowsByTaskId[taskId],
              shadow.windowId != 0 else { return false }
        ChromiumLauncher.sharedInstance().bridge?
            .createNewTab(withUrl: url,
                          windowId: Int64(shadow.windowId),
                          customGuid: nil,
                          focusAfterCreate: false)
        return true
    }

    /// Closes the task's shadow window and drops its record. Idempotent: the
    /// record is dropped first, so the `windowWillClose` callback this triggers
    /// finds nothing left to do.
    @discardableResult
    func closeShadowWindow(taskId: String, reason: String) -> Bool {
        guard let shadow = shadowWindowsByTaskId.removeValue(forKey: taskId) else {
            return false
        }
        AppLogInfo("[ShadowWindow] closing \(taskId) — windowId=\(shadow.windowId), reason=\(reason)")
        // The window is never key (alpha 0, ignoresMouseEvents, activation
        // suppressed), so this can't hand key to a hidden sibling the way a
        // Space window's close can.
        SpaceSessionControllersManager.shared
            .controller(for: shadow.windowId)?.window?.close()
        return true
    }

    /// Chromium tore the window down on its own — the last tab closed (shadow
    /// browsers skip placeholder mode), the profile went away, or the app is
    /// quitting. Drop the record so a re-bind spawns a fresh window instead of
    /// handing out a dead windowId.
    func shadowWindowDidClose(windowId: Int) {
        guard let taskId = shadowWindowsByTaskId.first(
            where: { $0.value.windowId == windowId })?.key else { return }
        AppLogInfo("[ShadowWindow] \(taskId) window \(windowId) closed by Chromium")
        shadowWindowsByTaskId.removeValue(forKey: taskId)
    }

    // MARK: - Keep-alive

    /// Refreshes the task's expiry. Same contract as `touchKeepAlive` for
    /// Spaces: a plain control message never shortens a deadline an explicit
    /// ping already bought.
    func touchShadowKeepAlive(taskId: String, ttlSeconds: Double? = nil) {
        guard var shadow = shadowWindowsByTaskId[taskId] else { return }
        if let ttl = ttlSeconds {
            let clamped = min(max(ttl, 1), Self.maxKeepAliveTTL)
            shadow.keepAliveDeadline = Date().addingTimeInterval(clamped)
        } else {
            shadow.keepAliveDeadline = max(
                shadow.keepAliveDeadline,
                Date().addingTimeInterval(Self.defaultKeepAliveTTL))
        }
        shadowWindowsByTaskId[taskId] = shadow
    }

    /// Reclaims shadow windows whose driver has gone silent. This matters more
    /// than it does for Spaces: a leaked Space is a stale pip the user can see
    /// and close, a leaked shadow window is an invisible window burning a
    /// renderer with no UI affordance to reach it.
    ///
    /// `.cdp` only — phi-agent shadow runs have their own backend lifecycle.
    func sweepExpiredShadowWindows(now: Date) {
        let expired = shadowWindowsByTaskId.values.filter {
            $0.origin == .cdp && $0.keepAliveDeadline < now
        }
        for shadow in expired {
            closeShadowWindow(taskId: shadow.taskId, reason: "expired: no agent activity")
        }
    }

    // MARK: - Queries

    func shadowWindow(forTaskId taskId: String) -> ShadowWindow? {
        shadowWindowsByTaskId[taskId]
    }

    /// Shadow windows visible to one caller — its own origin and principal
    /// only, so a driver can't enumerate another agent's background work.
    /// In-flight spawns (windowId 0) are omitted: there is nothing to drive yet.
    func shadowWindows(
        forOrigin origin: AgentTaskOrigin,
        principalId: String?
    ) -> [ShadowWindow] {
        shadowWindowsByTaskId.values
            .filter { $0.windowId != 0 }
            .filter {
                AgentTaskAccessPolicy.allows(
                    taskOrigin: $0.origin,
                    taskPrincipalId: $0.driverPrincipalId,
                    callerOrigin: origin,
                    callerPrincipalId: principalId)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }
}
