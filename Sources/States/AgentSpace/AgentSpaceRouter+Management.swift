// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import PostHog

/// The management slice of the `agentSpace.*` message surface: operating the
/// browser's user-facing features (Spaces, profiles, URL rules, tab groups,
/// split view, pinned tabs, bookmarks) rather than the agent-task lifecycle
/// handled in AgentSpaceRouter.swift.
///
/// Conventions match the lifecycle handlers: messages arrive on the main
/// thread (main-actor state via `MainActor.assumeIsolated`), replies are JSON
/// with the `ok`/`error` shape. App-level data operations (Spaces, profiles,
/// URL rules, pinned tabs, bookmarks) are informational-origin like
/// `agentSpace.listProfiles` — they act on shared app state that both origins
/// may manage. Window-scoped operations (tab groups, split view) are
/// task-scoped and origin-guarded: they act inside the calling task's own
/// agent window only.
extension AgentSpaceRouter {
    static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"encode_failed\"}"
        }
        return text
    }

    /// Settings ▸ Developer ▸ Agent permissions gate: when the toggle is off,
    /// agent tooling may only operate inside its own agent Spaces — every
    /// user-space management message refuses with this response. nil means
    /// allowed.
    static func userSpaceOperationsRefusal() -> String? {
        if MainBrowserWindowControllersManager.shared
            .isGuestTransitionInteractionBlocked {
            return failure("guest_account_transition_in_progress")
        }
        guard !PhiPreferences.AgentSpaces.userSpaceOperationsEnabled else { return nil }
        return failure("user_space_operations_disabled")
    }

    static func failure(_ error: String) -> String {
        encode(["ok": false, "error": error])
    }

    // MARK: - Spaces

    /// `agentSpace.spaces.list` — the user's normal Spaces. Agent Spaces and
    /// Incognito Spaces are excluded: the former have their own lifecycle
    /// surface, the latter are runtime-only and not managed via this API.
    /// `windowIds` lists the Space's open windows (empty when none) so a
    /// caller can address one specific window when several show the Space.
    static func handleSpacesList(context: ExtensionMessageContext) -> String? {
        let spaces = MainActor.assumeIsolated { () -> [[String: Any]] in
            let manager = SpaceManager.shared
            let activeId = manager.activeSpaceId
            let controllers = MainBrowserWindowControllersManager.shared.getAllWindows()
            return manager.spaces
                .filter { !$0.isAgentSpace && !SpaceManager.isIncognitoSpaceId($0.spaceId) }
                .map { space in
                    [
                        "spaceId": space.spaceId,
                        "name": space.name,
                        "colorHex": space.colorHex,
                        "iconName": space.iconName,
                        "profileId": space.profileId,
                        "sortOrder": space.sortOrder,
                        "isDefault": space.spaceId == LocalStore.defaultSpaceId,
                        "isActive": space.spaceId == activeId,
                        "windowIds": controllers
                            .filter { $0.spaceId == space.spaceId }
                            .map(\.windowId),
                    ]
                }
        }
        return encode(["ok": true, "spaces": spaces])
    }

    /// `agentSpace.spaces.create` — create a normal user Space. `profileId`
    /// accepts a profile id or display name; defaults to the active Space's
    /// profile (matching the UI's one-click "+" path). `activate: true`
    /// surfaces the new Space in the focused window — off by default so a
    /// background create never yanks the user's window.
    static func handleSpacesCreate(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let rawName = obj["name"] as? String else { return invalid() }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return invalid() }
        let colorHex = (obj["colorHex"] as? String) ?? "#3A6FF8"
        let iconName = (obj["iconName"] as? String) ?? "phi:phi-icon-view-grid-add"
        let activate = obj["activate"] as? Bool ?? false
        let requestedProfile = (obj["profileId"] as? String) ?? ""

        return MainActor.assumeIsolated {
            let manager = SpaceManager.shared
            ProfileManager.shared.refresh()
            let profiles = ProfileManager.shared.profiles
            let profileId: String
            if !requestedProfile.isEmpty {
                guard let match = profiles.first(where: {
                    $0.profileId == requestedProfile || $0.displayName == requestedProfile
                }) else { return failure("unknown_profile") }
                profileId = match.profileId
            } else if let active = manager.activeSpaceId,
                      let activeSpace = manager.spaces.first(where: { $0.spaceId == active }),
                      !SpaceManager.isIncognitoSpaceId(active) {
                profileId = activeSpace.profileId
            } else {
                profileId = profiles.first?.profileId ?? LocalStore.defaultProfileId
            }
            guard let spaceId = manager.createSpace(name: name,
                                                    colorHex: colorHex,
                                                    iconName: iconName,
                                                    profileId: profileId,
                                                    makeDefaultActive: false) else {
                return failure("no_account")
            }
            if activate {
                manager.activateInFocusedWindow(spaceId: spaceId)
            }
            return encode(["ok": true, "spaceId": spaceId, "profileId": profileId])
        }
    }

    /// `agentSpace.spaces.update` — rename / recolor / change icon. All
    /// fields optional and independent.
    static func handleSpacesUpdate(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let spaceId = obj["spaceId"] as? String else { return invalid() }
        return MainActor.assumeIsolated {
            let manager = SpaceManager.shared
            guard let space = manager.spaces.first(where: { $0.spaceId == spaceId }) else {
                return failure("unknown_space")
            }
            guard !space.isAgentSpace else { return failure("agent_space") }
            if let name = (obj["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                manager.renameSpace(spaceId: spaceId, to: name)
            }
            if let colorHex = obj["colorHex"] as? String, !colorHex.isEmpty {
                manager.recolorSpace(spaceId: spaceId, colorHex: colorHex)
            }
            if let iconName = obj["iconName"] as? String, !iconName.isEmpty {
                manager.changeIcon(spaceId: spaceId, iconName: iconName)
            }
            return ok()
        }
    }

    /// `agentSpace.spaces.delete` — delete a normal user Space (closes its
    /// windows, cascade-deletes its bookmarks and URL rules). The default
    /// Space and agent Spaces are refused; an import in progress is reported
    /// as an error instead of tripping `deleteSpace`'s modal alert.
    static func handleSpacesDelete(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let spaceId = obj["spaceId"] as? String else { return invalid() }
        return MainActor.assumeIsolated {
            let manager = SpaceManager.shared
            guard spaceId != LocalStore.defaultSpaceId else { return failure("default_space") }
            guard let space = manager.spaces.first(where: { $0.spaceId == spaceId }) else {
                return failure("unknown_space")
            }
            guard !space.isAgentSpace else { return failure("agent_space") }
            guard !ImportTargetLock.shared.isImporting(into: spaceId) else {
                return failure("import_in_progress")
            }
            manager.deleteSpace(spaceId: spaceId)
            return ok()
        }
    }

    /// `agentSpace.spaces.listTabs` — a user Space's open tabs (its window's
    /// full listable inventory: normal, open pinned, and bookmark-opened
    /// tabs alike), as {tabId, url, title, active, kind} with `kind` one of
    /// normal|pinned|bookmark. Fails when the Space has no open window
    /// (only live windows have a tab strip to read) and `window_not_ready`
    /// when the window exists but its state has not attached yet — a
    /// transient worth retrying, never a silent empty list. An optional
    /// `windowId` reads one specific window's strip instead of the
    /// key-window default, failing `window_not_open` when that window does
    /// not show the Space; with `windowId` alone the Space is derived from
    /// the window. The reply echoes the resolved `spaceId` either way.
    static func handleSpacesListTabs(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload) else { return invalid() }
        let spaceId = obj["spaceId"] as? String
        let windowId = obj["windowId"] as? Int
        guard spaceId != nil || windowId != nil else { return invalid() }
        return MainActor.assumeIsolated {
            let target: (windowId: Int, state: BrowserState?, spaceId: String)?
            if let spaceId {
                target = spaceWindow(spaceId: spaceId, windowId: windowId)
                    .map { ($0.windowId, $0.state, spaceId) }
            } else {
                target = windowSpace(windowId: windowId!)
            }
            guard let target else {
                return failure(windowId == nil ? "space_not_open" : "window_not_open")
            }
            guard let state = target.state else {
                return failure("window_not_ready")
            }
            let tabs = state.agentTabInventory().map { entry -> [String: Any] in
                [
                    "tabId": entry.tab.guid,
                    "url": entry.tab.url ?? "",
                    "title": entry.tab.title,
                    "active": entry.tab.isActive,
                    "kind": entry.kind,
                ]
            }
            return encode(["ok": true, "windowId": target.windowId,
                           "spaceId": target.spaceId, "tabs": tabs])
        }
    }

    /// `agentSpace.spaces.openTab` — open a URL as a new tab in a user
    /// Space's open window: the direct user-Space counterpart of the
    /// task-scoped `agentSpace.openTab`. `activate` (default true) selects
    /// the new tab — the common caller is opening a page *for* the user to
    /// see. Fails when the Space has no open window, like `spaces.listTabs`;
    /// an optional `windowId` targets one specific window instead of the
    /// key-window default.
    static func handleSpacesOpenTab(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let spaceId = obj["spaceId"] as? String,
              let url = obj["url"] as? String, !url.isEmpty else { return invalid() }
        let activate = obj["activate"] as? Bool ?? true
        let windowId = obj["windowId"] as? Int
        return MainActor.assumeIsolated {
            guard let target = spaceWindow(spaceId: spaceId, windowId: windowId) else {
                return failure(windowId == nil ? "space_not_open" : "window_not_open")
            }
            // Opening a tab here IS the agent operating the user's Space, but
            // the app performs it itself — no CDP command is sent, so the
            // browser's drive reports never see it. Arm the operating mask
            // from this side instead, matched to the tab Chromium is about to
            // create. Agent Spaces keep deriving their own mask from the task.
            let isAgentSpace = SpaceManager.shared.spaces
                .first { $0.spaceId == spaceId }?.isAgentSpace ?? false
            if !isAgentSpace {
                AgentUserSpaceDriveRegistry.shared.agentWillOpenTab(
                    inWindow: target.windowId,
                    principalId: context.driverPrincipalId,
                    driverName: context.agentName)
            }
            ChromiumLauncher.sharedInstance().bridge?
                .createNewTab(withUrl: url,
                              windowId: Int64(target.windowId),
                              customGuid: nil,
                              focusAfterCreate: activate)
            return encode(["ok": true, "windowId": target.windowId])
        }
    }

    /// `agentSpace.spaces.activate` — surface a user Space in the focused
    /// window, opening its window when it has none: the programmatic
    /// counterpart of clicking the Space in the switcher. On-screen change,
    /// so callers invoke it only on the user's ask (or when a Space they
    /// were asked to work in has no window to drive).
    static func handleSpacesActivate(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let spaceId = obj["spaceId"] as? String else { return invalid() }
        return MainActor.assumeIsolated {
            let manager = SpaceManager.shared
            guard let space = manager.spaces.first(where: { $0.spaceId == spaceId }) else {
                return failure("unknown_space")
            }
            guard !space.isAgentSpace else { return failure("agent_space") }
            manager.activateInFocusedWindow(spaceId: spaceId)
            return ok()
        }
    }

    /// `agentSpace.spaces.focus` — where the user currently is: the active
    /// Space (same source as `spaces.list`'s `isActive`) plus its window and
    /// selected tab when the Space has an open window. The tab detail is
    /// withheld for Incognito Spaces — they are runtime-only and not part of
    /// the managed surface.
    static func handleSpacesFocus(context: ExtensionMessageContext) -> String? {
        return MainActor.assumeIsolated {
            let manager = SpaceManager.shared
            guard let spaceId = manager.activeSpaceId else {
                return failure("no_active_space")
            }
            let space = manager.spaces.first { $0.spaceId == spaceId }
            var reply: [String: Any] = [
                "ok": true,
                "spaceId": spaceId,
                "spaceName": space?.name ?? "",
                "isAgentSpace": space?.isAgentSpace ?? false,
                "isIncognito": SpaceManager.isIncognitoSpaceId(spaceId),
            ]
            if !SpaceManager.isIncognitoSpaceId(spaceId),
               let target = spaceWindow(spaceId: spaceId) {
                reply["windowId"] = target.windowId
                if let tab = (target.state?.normalTabs ?? []).first(where: { $0.isActive }) {
                    reply["tab"] = ["tabId": tab.guid,
                                    "url": tab.url ?? "",
                                    "title": tab.title]
                }
            }
            return encode(reply)
        }
    }

    // MARK: - Profiles

    /// `agentSpace.profiles.create` — async: bridge round-trip, then reply
    /// with the new profile id.
    static func handleProfilesCreate(context: ExtensionMessageContext) {
        let requestId = context.requestId
        guard let obj = json(context.payload),
              let name = (obj["displayName"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            MainActor.assumeIsolated {
                ExtensionMessaging.shared.sendResponse(invalid(), requestId: requestId)
            }
            return
        }
        MainActor.assumeIsolated {
            ProfileManager.shared.createProfile(displayName: name) { newId in
                if let newId {
                    ExtensionMessaging.shared.sendResponse(
                        encode(["ok": true, "profileId": newId]), requestId: requestId)
                } else {
                    // createProfile fails on empty/duplicate names or a
                    // missing bridge; the name checks are the common case.
                    ExtensionMessaging.shared.sendResponse(
                        failure("invalid_or_duplicate_name"), requestId: requestId)
                }
            }
        }
    }

    /// `agentSpace.profiles.rename` — async: bridge round-trip, then ok.
    static func handleProfilesRename(context: ExtensionMessageContext) {
        let requestId = context.requestId
        guard let obj = json(context.payload),
              let profileId = obj["profileId"] as? String,
              let name = (obj["displayName"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            MainActor.assumeIsolated {
                ExtensionMessaging.shared.sendResponse(invalid(), requestId: requestId)
            }
            return
        }
        MainActor.assumeIsolated {
            guard ProfileManager.shared.profile(for: profileId) != nil else {
                ExtensionMessaging.shared.sendResponse(
                    failure("unknown_profile"), requestId: requestId)
                return
            }
            ProfileManager.shared.renameProfile(profileId, to: name) { success, error in
                if success {
                    ExtensionMessaging.shared.sendResponse(ok(), requestId: requestId)
                } else {
                    ExtensionMessaging.shared.sendResponse(
                        failure(error ?? "invalid_or_duplicate_name"), requestId: requestId)
                }
            }
        }
    }

    // MARK: - URL rules

    private static func draft(from rule: SpaceURLRule) -> LocalStore.URLRuleDraft {
        LocalStore.URLRuleDraft(host: rule.host,
                                pathPrefix: rule.pathPrefix,
                                askBeforeRouting: rule.askBeforeRouting,
                                createdDate: rule.createdDate)
    }

    /// Committed rule rows, straight from the store. The manager's
    /// `allRules` cache lags a background write until the publisher
    /// round-trips, so a mutation based on it could silently drop a change
    /// a client made moments earlier; the store fetch is authoritative.
    @MainActor
    private static func storedRules() -> [SpaceURLRule] {
        AccountController.shared.localDataAccount?.localStorage.getAllURLRules() ?? []
    }

    /// A rule may target any existing normal Space, or the Incognito rule
    /// target ("route to an Incognito Space, created on demand").
    @MainActor
    private static func isValidRuleTarget(_ spaceId: String) -> Bool {
        if spaceId == SpaceManager.incognitoRuleTargetId { return true }
        return SpaceManager.shared.spaces.contains {
            $0.spaceId == spaceId && !$0.isAgentSpace &&
            !SpaceManager.isIncognitoSpaceId($0.spaceId)
        }
    }

    /// `agentSpace.urlRules.list` — every Space's rules. Row ids are stable
    /// until the next rule write (the store regenerates ids on save), so
    /// list-then-mutate within one round is the intended use.
    static func handleUrlRulesList(context: ExtensionMessageContext) -> String? {
        let rules = MainActor.assumeIsolated {
            storedRules().map { rule -> [String: Any] in
                [
                    "id": rule.id,
                    "spaceId": rule.spaceId,
                    "host": rule.host,
                    "pathPrefix": rule.pathPrefix as Any? ?? NSNull(),
                    "ask": rule.askBeforeRouting,
                    "sortOrder": rule.sortOrder,
                ]
            }
        }
        return encode(["ok": true, "rules": rules])
    }

    /// `agentSpace.urlRules.add` — append one rule to `spaceId`'s rule set.
    /// `host` accepts the three matcher forms ("github.com", "*.figma.com",
    /// "*git*"); `pathPrefix` is canonicalized by the draft.
    static func handleUrlRulesAdd(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let spaceId = obj["spaceId"] as? String,
              let rawHost = obj["host"] as? String else { return invalid() }
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return invalid() }
        return MainActor.assumeIsolated {
            guard isValidRuleTarget(spaceId) else { return failure("unknown_space") }
            let manager = SpaceManager.shared
            var drafts = storedRules()
                .filter { $0.spaceId == spaceId }
                .map(draft(from:))
            drafts.append(LocalStore.URLRuleDraft(
                host: host,
                pathPrefix: obj["pathPrefix"] as? String,
                askBeforeRouting: obj["ask"] as? Bool ?? false))
            manager.setRules(drafts, forSpaceId: spaceId)
            return ok()
        }
    }

    /// `agentSpace.urlRules.update` — modify one rule by id (from a fresh
    /// `urlRules.list`). Optional `host` / `pathPrefix` / `ask` / `spaceId`
    /// (the latter moves the rule to another Space's set). Position is
    /// preserved when the Space is unchanged.
    static func handleUrlRulesUpdate(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let id = obj["id"] as? String else { return invalid() }
        return MainActor.assumeIsolated {
            let manager = SpaceManager.shared
            let all = storedRules()
            guard let existing = all.first(where: { $0.id == id }) else {
                return failure("unknown_rule")
            }
            let newHost = ((obj["host"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()) ?? existing.host
            guard !newHost.isEmpty else { return invalid() }
            // Distinguish "pathPrefix absent" (keep) from "pathPrefix: null
            // or empty" (clear) — the draft's normalizer maps empty to nil.
            let newPath: String?
            if obj.keys.contains("pathPrefix") {
                newPath = obj["pathPrefix"] as? String
            } else {
                newPath = existing.pathPrefix
            }
            let newAsk = obj["ask"] as? Bool ?? existing.askBeforeRouting
            let newSpace = obj["spaceId"] as? String ?? existing.spaceId
            if newSpace != existing.spaceId {
                guard isValidRuleTarget(newSpace) else { return failure("unknown_space") }
            }
            var byTarget: [String: [LocalStore.URLRuleDraft]] = [:]
            for rule in all {
                if rule.id == id {
                    byTarget[newSpace, default: []].append(LocalStore.URLRuleDraft(
                        host: newHost,
                        pathPrefix: newPath,
                        askBeforeRouting: newAsk,
                        createdDate: rule.createdDate))
                } else {
                    byTarget[rule.spaceId, default: []].append(draft(from: rule))
                }
            }
            manager.setAllRules(byTarget)
            return ok()
        }
    }

    /// `agentSpace.urlRules.delete` — remove one rule by id.
    static func handleUrlRulesDelete(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let id = obj["id"] as? String else { return invalid() }
        return MainActor.assumeIsolated {
            let manager = SpaceManager.shared
            let all = storedRules()
            guard all.contains(where: { $0.id == id }) else {
                return failure("unknown_rule")
            }
            var byTarget: [String: [LocalStore.URLRuleDraft]] = [:]
            for rule in all where rule.id != id {
                byTarget[rule.spaceId, default: []].append(draft(from: rule))
            }
            // Buckets that just lost their only rule must still be present so
            // setAllRules clears them — seed every Space that had rules.
            for rule in all where byTarget[rule.spaceId] == nil {
                byTarget[rule.spaceId] = []
            }
            manager.setAllRules(byTarget)
            return ok()
        }
    }

    // MARK: - Tab groups / split view

    /// Resolves a task-scoped window operation's target. Origin-guarded like
    /// every other task-scoped control message.
    @MainActor
    private static func taskWindow(taskId: String)
        -> (windowId: Int, state: BrowserState?)? {
        guard let task = AgentSpaceManager.shared.task(forTaskId: taskId),
              task.windowId != 0 else { return nil }
        return (task.windowId,
                MainBrowserWindowControllersManager.shared.getBrowserState(for: task.windowId))
    }

    /// Resolves a user Space's open window (its slot's registered controller,
    /// visible or not). A caller-supplied `windowId` narrows to that exact
    /// window (nil when it does not show the Space); otherwise the key window
    /// wins when several show the Space. Agent Spaces are refused here: their
    /// windows are ownership-guarded and must be addressed through the taskId
    /// path.
    @MainActor
    private static func spaceWindow(spaceId: String, windowId: Int? = nil)
        -> (windowId: Int, state: BrowserState?)? {
        guard !AgentSpaceManager.shared.isAgentSpace(spaceId) else { return nil }
        let controllers = MainBrowserWindowControllersManager.shared.getAllWindows()
            .filter { $0.spaceId == spaceId }
        if let windowId {
            guard let chosen = controllers.first(where: { $0.windowId == windowId })
            else { return nil }
            return (chosen.windowId, chosen.browserState)
        }
        guard let chosen = controllers.first(where: { $0.window?.isKeyWindow == true })
            ?? controllers.first else { return nil }
        return (chosen.windowId, chosen.browserState)
    }

    /// The reverse of `spaceWindow`: resolves an open window to it plus the
    /// user Space it shows. Nil for unknown ids and for agent-Space windows
    /// (ownership-guarded — taskId path only, same as `spaceWindow`).
    @MainActor
    private static func windowSpace(windowId: Int)
        -> (windowId: Int, state: BrowserState?, spaceId: String)? {
        guard let chosen = MainBrowserWindowControllersManager.shared.getAllWindows()
            .first(where: { $0.windowId == windowId }),
            !AgentSpaceManager.shared.isAgentSpace(chosen.spaceId) else { return nil }
        return (chosen.windowId, chosen.browserState, chosen.spaceId)
    }

    /// Routes a tab-layout message to its target window: `spaceId` addresses
    /// a user Space's open window (app-level, like the rest of the management
    /// surface; an optional `windowId` narrows to one specific window),
    /// `taskId` keeps the origin-guarded agent-window path. The same
    /// operation body runs against either.
    private static func withLayoutWindow(
        _ obj: [String: Any],
        context: ExtensionMessageContext,
        _ body: @MainActor ((windowId: Int, state: BrowserState?)) -> String?
    ) -> String? {
        if let spaceId = obj["spaceId"] as? String {
            if let denied = userSpaceOperationsRefusal() { return denied }
            let windowId = obj["windowId"] as? Int
            // The spaceId path targets a USER Space's window (the taskId path
            // below is the agent's own window) — count it as user-space usage.
            PostHogSDK.shared.capture("agent_user_space_command", properties: [
                "command": context.type,
                "agent_name": AgentDriverBadge.telemetryName(context.agentName),
            ])
            return MainActor.assumeIsolated {
                guard let target = spaceWindow(spaceId: spaceId, windowId: windowId) else {
                    return failure(windowId == nil ? "space_not_open" : "window_not_open")
                }
                return body(target)
            }
        }
        guard let taskId = obj["taskId"] as? String else { return invalid() }
        guard callerMayControl(taskId: taskId, context: context) else { return unknownTask() }
        return MainActor.assumeIsolated {
            guard let target = taskWindow(taskId: taskId) else { return unknownTask() }
            return body(target)
        }
    }

    private static func intArray(_ value: Any?) -> [Int]? {
        guard let raw = value as? [Any] else { return nil }
        let ints = raw.compactMap { ($0 as? NSNumber)?.intValue }
        return ints.count == raw.count ? ints : nil
    }

    /// `agentSpace.tabGroups.list` — the target window's groups with their
    /// member tab ids.
    static func handleTabGroupsList(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload) else { return invalid() }
        return withLayoutWindow(obj, context: context) { target in
            guard let state = target.state else { return encode(["ok": true, "groups": []]) }
            let groups = state.groups.map { token, info -> [String: Any] in
                [
                    "token": token,
                    "title": info.title,
                    "color": info.color.rawValue,
                    "collapsed": info.isCollapsed,
                    "tabIds": state.normalTabs
                        .filter { $0.groupToken == token }
                        .map(\.guid),
                ]
            }
            return encode(["ok": true, "groups": groups])
        }
    }

    /// `agentSpace.tabGroups.create` — group the given tabs in the target
    /// window. Optional `title` and `color` (Chromium wire strings:
    /// grey/blue/red/yellow/green/pink/purple/cyan/orange).
    static func handleTabGroupsCreate(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let tabIds = intArray(obj["tabIds"]), !tabIds.isEmpty else { return invalid() }
        if let color = obj["color"] as? String, GroupColor(rawValue: color) == nil {
            return failure("unknown_color")
        }
        return withLayoutWindow(obj, context: context) { target in
            guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
                return failure("bridge_unavailable")
            }
            let token = bridge.createGroupFromTabs(
                withWindowId: Int64(target.windowId),
                tabIds: tabIds.map { NSNumber(value: Int64($0)) },
                title: obj["title"] as? String,
                color: obj["color"] as? String)
            guard !token.isEmpty else { return failure("create_failed") }
            return encode(["ok": true, "token": token])
        }
    }

    /// `agentSpace.tabGroups.update` — title / color / collapsed, each
    /// optional and independent.
    static func handleTabGroupsUpdate(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let token = obj["token"] as? String else { return invalid() }
        if let color = obj["color"] as? String, GroupColor(rawValue: color) == nil {
            return failure("unknown_color")
        }
        return withLayoutWindow(obj, context: context) { target in
            guard target.state?.groups[token] != nil else { return failure("unknown_group") }
            guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
                return failure("bridge_unavailable")
            }
            let windowId = Int64(target.windowId)
            if let title = obj["title"] as? String {
                bridge.updateTabGroupTitle(withWindowId: windowId, tokenHex: token, title: title)
            }
            if let color = obj["color"] as? String {
                bridge.updateTabGroupColor(withWindowId: windowId, tokenHex: token, color: color)
            }
            if let collapsed = obj["collapsed"] as? Bool {
                bridge.updateTabGroupCollapsed(withWindowId: windowId, tokenHex: token,
                                               isCollapsed: collapsed)
            }
            return ok()
        }
    }

    /// `agentSpace.tabGroups.addTabs` — add tabs to an existing group.
    static func handleTabGroupsAddTabs(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let token = obj["token"] as? String,
              let tabIds = intArray(obj["tabIds"]), !tabIds.isEmpty else { return invalid() }
        return withLayoutWindow(obj, context: context) { target in
            guard target.state?.groups[token] != nil else { return failure("unknown_group") }
            guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
                return failure("bridge_unavailable")
            }
            bridge.addTabsToGroup(withWindowId: Int64(target.windowId),
                                  tabIds: tabIds.map { NSNumber(value: Int64($0)) },
                                  tokenHex: token)
            return ok()
        }
    }

    /// `agentSpace.tabGroups.removeTabs` — remove tabs from whichever group
    /// they belong to (a group whose last member leaves closes itself).
    static func handleTabGroupsRemoveTabs(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let tabIds = intArray(obj["tabIds"]), !tabIds.isEmpty else { return invalid() }
        return withLayoutWindow(obj, context: context) { target in
            guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
                return failure("bridge_unavailable")
            }
            bridge.removeTabsFromGroup(withWindowId: Int64(target.windowId),
                                       tabIds: tabIds.map { NSNumber(value: Int64($0)) })
            return ok()
        }
    }

    /// `agentSpace.tabGroups.ungroup` — dissolve a group, keeping its tabs.
    static func handleTabGroupsUngroup(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let token = obj["token"] as? String else { return invalid() }
        return withLayoutWindow(obj, context: context) { target in
            guard let state = target.state, state.groups[token] != nil else {
                return failure("unknown_group")
            }
            guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
                return failure("bridge_unavailable")
            }
            let members = state.normalTabs.filter { $0.groupToken == token }.map(\.guid)
            guard !members.isEmpty else { return ok() }
            bridge.removeTabsFromGroup(withWindowId: Int64(target.windowId),
                                       tabIds: members.map { NSNumber(value: Int64($0)) })
            return ok()
        }
    }

    /// `agentSpace.tabGroups.close` — close a group AND all of its tabs.
    static func handleTabGroupsClose(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let token = obj["token"] as? String else { return invalid() }
        return withLayoutWindow(obj, context: context) { target in
            guard target.state?.groups[token] != nil else { return failure("unknown_group") }
            guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
                return failure("bridge_unavailable")
            }
            bridge.closeGroup(withWindowId: Int64(target.windowId), tokenHex: token)
            return ok()
        }
    }

    /// `agentSpace.splitView.list` — the target window's splits.
    static func handleSplitViewList(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload) else { return invalid() }
        return withLayoutWindow(obj, context: context) { target in
            let splits = (target.state?.splits ?? []).map { split -> [String: Any] in
                [
                    "splitId": split.id,
                    "primaryTabId": split.primaryTabId,
                    "secondaryTabId": split.secondaryTabId,
                    "layout": split.layout.rawValue,
                    "ratio": split.ratio,
                ]
            }
            return encode(["ok": true, "splits": splits])
        }
    }

    /// `agentSpace.splitView.create` — split two of the target window's tabs
    /// side by side. `layout`: "vertical" (side-by-side, default) or
    /// "horizontal" (stacked). Routes through BrowserState so the focused
    /// tab lands in the primary argument (renderer-visibility nuance).
    static func handleSplitViewCreate(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let primary = (obj["primaryTabId"] as? NSNumber)?.intValue,
              let secondary = (obj["secondaryTabId"] as? NSNumber)?.intValue,
              primary != secondary else { return invalid() }
        let layoutRaw = obj["layout"] as? String ?? SplitLayout.vertical.rawValue
        guard let layout = SplitLayout(rawValue: layoutRaw) else { return invalid() }
        return withLayoutWindow(obj, context: context) { target in
            guard let state = target.state else { return failure("window_unavailable") }
            guard let splitId = state.createSplit(leftTabId: primary,
                                                  rightTabId: secondary,
                                                  layout: layout) else {
                return failure("create_failed")
            }
            return encode(["ok": true, "splitId": splitId])
        }
    }

    /// `agentSpace.splitView.update` — ratio (0–1, primary pane's share)
    /// and/or layout.
    static func handleSplitViewUpdate(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let splitId = obj["splitId"] as? String else { return invalid() }
        let layout: SplitLayout?
        if let layoutRaw = obj["layout"] as? String {
            guard let parsed = SplitLayout(rawValue: layoutRaw) else { return invalid() }
            layout = parsed
        } else {
            layout = nil
        }
        return withLayoutWindow(obj, context: context) { target in
            guard let state = target.state,
                  state.splitGroup(forId: splitId) != nil else { return failure("unknown_split") }
            if let ratio = (obj["ratio"] as? NSNumber)?.doubleValue {
                state.updateSplitRatio(splitId, ratio: ratio)
            }
            if let layout {
                state.updateSplitLayout(splitId, layout: layout)
            }
            return ok()
        }
    }

    /// `agentSpace.splitView.swap` — swap the two panes.
    static func handleSplitViewSwap(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let splitId = obj["splitId"] as? String else { return invalid() }
        return withLayoutWindow(obj, context: context) { target in
            guard let state = target.state,
                  state.splitGroup(forId: splitId) != nil else { return failure("unknown_split") }
            state.reverseTabsInSplit(splitId)
            return ok()
        }
    }

    /// `agentSpace.splitView.remove` — disband the split; both tabs stay open.
    static func handleSplitViewRemove(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let splitId = obj["splitId"] as? String else { return invalid() }
        return withLayoutWindow(obj, context: context) { target in
            guard let state = target.state,
                  state.splitGroup(forId: splitId) != nil else { return failure("unknown_split") }
            state.removeSplit(splitId)
            return ok()
        }
    }

    // MARK: - Pinned tabs

    /// Resolves an optional profile reference (id or display name) to a
    /// profileId; nil/empty falls back to the active Space's profile, then
    /// the first profile.
    @MainActor
    private static func resolveProfileId(_ requested: String?) -> String? {
        ProfileManager.shared.refresh()
        let profiles = ProfileManager.shared.profiles
        if let requested, !requested.isEmpty {
            return profiles.first(where: {
                $0.profileId == requested || $0.displayName == requested
            })?.profileId
        }
        let manager = SpaceManager.shared
        if let active = manager.activeSpaceId,
           !SpaceManager.isIncognitoSpaceId(active),
           let activeSpace = manager.spaces.first(where: { $0.spaceId == active }) {
            return activeSpace.profileId
        }
        return profiles.first?.profileId ?? LocalStore.defaultProfileId
    }

    private static func resolvePinnedTabSpaceId(_ requested: String?, profileId: String) -> String {
        let manager = SpaceManager.shared
        if let requested,
           manager.spaces.contains(where: { $0.spaceId == requested && $0.profileId == profileId }) {
            return requested
        }
        if let activeSpaceId = manager.activeSpaceId,
           manager.spaces.contains(where: { $0.spaceId == activeSpaceId && $0.profileId == profileId }) {
            return activeSpaceId
        }
        return manager.spaces.first(where: { $0.profileId == profileId })?.spaceId
            ?? LocalStore.defaultSpaceId
    }

    /// `agentSpace.pinnedTabs.list` — pinned-tab records visible in the
    /// requested profile and Space under the user's configured scope.
    static func handlePinnedTabsList(context: ExtensionMessageContext) -> String? {
        let object = json(context.payload)
        let requested = object?["profileId"] as? String
        return MainActor.assumeIsolated {
            guard let store = AccountController.shared.localDataAccount?.localStorage else {
                return failure("no_account")
            }
            guard let profileId = resolveProfileId(requested) else {
                return failure("unknown_profile")
            }
            let spaceId = resolvePinnedTabSpaceId(object?["spaceId"] as? String, profileId: profileId)
            let pinned = store.getAllPinnedTabs(for: profileId, spaceId: spaceId).map { model -> [String: Any] in
                [
                    "guid": model.guid,
                    "url": model.url.absoluteString,
                    "title": model.title,
                    "index": model.index,
                    "profileId": profileId,
                    "spaceId": spaceId,
                ]
            }
            return encode(["ok": true, "pinnedTabs": pinned])
        }
    }

    /// `agentSpace.pinnedTabs.add` — create a pinned-tab record from a URL.
    /// It appears in every window covered by the configured pinned-tab scope.
    /// Optional `index` positions it.
    static func handlePinnedTabsAdd(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let url = obj["url"] as? String,
              URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        else { return invalid() }
        return MainActor.assumeIsolated {
            guard let store = AccountController.shared.localDataAccount?.localStorage else {
                return failure("no_account")
            }
            guard let profileId = resolveProfileId(obj["profileId"] as? String) else {
                return failure("unknown_profile")
            }
            let spaceId = resolvePinnedTabSpaceId(obj["spaceId"] as? String, profileId: profileId)
            let guid = UUID().uuidString
            store.createPinnedTab(guid: guid,
                                  url: url,
                                  title: (obj["title"] as? String) ?? "",
                                  profileId: profileId,
                                  spaceId: spaceId,
                                  index: (obj["index"] as? NSNumber)?.intValue)
            return encode(["ok": true, "guid": guid, "profileId": profileId, "spaceId": spaceId])
        }
    }

    /// `agentSpace.pinnedTabs.update` — change a pinned record's URL and/or
    /// title.
    static func handlePinnedTabsUpdate(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let guid = obj["guid"] as? String else { return invalid() }
        if let url = obj["url"] as? String,
           URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
            return invalid()
        }
        return MainActor.assumeIsolated {
            guard let store = AccountController.shared.localDataAccount?.localStorage else {
                return failure("no_account")
            }
            guard let model = store.getTab(by: guid),
                  model.dataType == .pinnedTab,
                  store.isPinnedTabInActiveScope(model) else {
                return failure("unknown_pinned_tab")
            }
            let url = (obj["url"] as? String).flatMap {
                URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            store.updateActivePinnedTab(
                guid: guid,
                url: url,
                title: obj["title"] as? String
            )
            return ok()
        }
    }

    /// `agentSpace.pinnedTabs.remove` — delete a pinned record.
    static func handlePinnedTabsRemove(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let guid = obj["guid"] as? String else { return invalid() }
        return MainActor.assumeIsolated {
            guard let store = AccountController.shared.localDataAccount?.localStorage else {
                return failure("no_account")
            }
            guard let model = store.getTab(by: guid),
                  model.dataType == .pinnedTab,
                  store.isPinnedTabInActiveScope(model) else {
                return failure("unknown_pinned_tab")
            }
            store.removeActivePinnedTab(guid: guid)
            return ok()
        }
    }

    // MARK: - Bookmarks

    /// Resolves the (profileId, spaceId) pair bookmark rows are keyed by.
    /// `spaceId` defaults to the default Space; the profile is the Space's
    /// bound profile.
    @MainActor
    private static func bookmarkScope(_ requestedSpaceId: String?)
        -> (profileId: String, spaceId: String)? {
        let spaceId = (requestedSpaceId?.isEmpty == false)
            ? requestedSpaceId! : LocalStore.defaultSpaceId
        guard let space = SpaceManager.shared.spaces.first(where: { $0.spaceId == spaceId })
        else { return nil }
        return (space.profileId, spaceId)
    }

    /// `agentSpace.bookmarks.list` — the Space's bookmark tree (bookmarks are
    /// per-Space). Folders carry `children`; leaves carry `url`.
    static func handleBookmarksList(context: ExtensionMessageContext) -> String? {
        let requestedSpace = json(context.payload)?["spaceId"] as? String
        return MainActor.assumeIsolated {
            guard let store = AccountController.shared.localDataAccount?.localStorage else {
                return failure("no_account")
            }
            guard let scope = bookmarkScope(requestedSpace) else {
                return failure("unknown_space")
            }
            @MainActor
            func node(_ model: TabDataModel, depth: Int) -> [String: Any] {
                var out: [String: Any] = [
                    "guid": model.guid,
                    "title": model.title,
                    "index": model.index,
                ]
                if model.dataType == .bookmarkFolder {
                    out["isFolder"] = true
                    // Bookmark trees are shallow in practice; the depth cap
                    // only guards against a pathological/corrupt cycle.
                    if depth < 20 {
                        out["children"] = store.fetchBookmarks(parentId: model.guid,
                                                               profileId: scope.profileId,
                                                               spaceId: scope.spaceId)
                            .map { node($0, depth: depth + 1) }
                    } else {
                        out["children"] = []
                    }
                } else {
                    out["isFolder"] = false
                    out["url"] = model.url.absoluteString
                    if let secondary = model.secondaryUrl {
                        out["secondaryUrl"] = secondary.absoluteString
                    }
                }
                return out
            }
            let roots = store.fetchBookmarks(parentId: nil,
                                             profileId: scope.profileId,
                                             spaceId: scope.spaceId)
                .map { node($0, depth: 0) }
            return encode(["ok": true, "spaceId": scope.spaceId,
                           "profileId": scope.profileId, "bookmarks": roots])
        }
    }

    /// `agentSpace.bookmarks.add` — create a bookmark. `parentGuid` nil means
    /// the Space's root; `index` positions it among siblings (appended when
    /// omitted). The write is asynchronous; the returned guid is final.
    static func handleBookmarksAdd(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let url = obj["url"] as? String, !url.isEmpty else { return invalid() }
        return MainActor.assumeIsolated {
            guard let store = AccountController.shared.localDataAccount?.localStorage else {
                return failure("no_account")
            }
            guard let scope = bookmarkScope(obj["spaceId"] as? String) else {
                return failure("unknown_space")
            }
            guard store.normalizedURL(from: url) != nil else { return failure("invalid_url") }
            if let parentGuid = obj["parentGuid"] as? String {
                guard let parent = store.fetchBookmark(with: parentGuid),
                      parent.dataType == .bookmarkFolder else {
                    return failure("unknown_folder")
                }
            }
            let guid = UUID().uuidString
            store.createBookmark(url: url,
                                 title: obj["title"] as? String,
                                 profileId: scope.profileId,
                                 parentId: obj["parentGuid"] as? String,
                                 index: (obj["index"] as? NSNumber)?.intValue,
                                 guid: guid,
                                 spaceId: scope.spaceId)
            return encode(["ok": true, "guid": guid])
        }
    }

    /// `agentSpace.bookmarks.addFolder` — create a bookmark folder.
    static func handleBookmarksAddFolder(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let title = (obj["title"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return invalid() }
        return MainActor.assumeIsolated {
            guard let store = AccountController.shared.localDataAccount?.localStorage else {
                return failure("no_account")
            }
            guard let scope = bookmarkScope(obj["spaceId"] as? String) else {
                return failure("unknown_space")
            }
            if let parentGuid = obj["parentGuid"] as? String {
                guard let parent = store.fetchBookmark(with: parentGuid),
                      parent.dataType == .bookmarkFolder else {
                    return failure("unknown_folder")
                }
            }
            let guid = UUID().uuidString
            store.createDirectory(title: title,
                                  profileId: scope.profileId,
                                  parentId: obj["parentGuid"] as? String,
                                  index: (obj["index"] as? NSNumber)?.intValue,
                                  guid: guid,
                                  spaceId: scope.spaceId)
            return encode(["ok": true, "guid": guid])
        }
    }

    /// `agentSpace.bookmarks.update` — retitle any node; change a bookmark's
    /// URL (folders have none).
    static func handleBookmarksUpdate(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let guid = obj["guid"] as? String else { return invalid() }
        return MainActor.assumeIsolated {
            guard let store = AccountController.shared.localDataAccount?.localStorage else {
                return failure("no_account")
            }
            guard let model = store.getTab(by: guid),
                  model.dataType == .bookmark || model.dataType == .bookmarkFolder,
                  let profileId = model.profileId else {
                return failure("unknown_bookmark")
            }
            let url = obj["url"] as? String
            if url != nil {
                guard model.dataType == .bookmark else { return failure("not_a_bookmark") }
                guard store.normalizedURL(from: url) != nil else { return failure("invalid_url") }
            }
            store.updateBookmark(guid,
                                 profileId: profileId,
                                 title: obj["title"] as? String,
                                 url: url)
            return encode(["ok": true, "spaceId": model.spaceId ?? LocalStore.defaultSpaceId])
        }
    }

    /// `agentSpace.bookmarks.move` — reparent and/or reorder. `parentGuid`
    /// nil targets the Space's root; `index` omitted appends.
    static func handleBookmarksMove(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let guid = obj["guid"] as? String else { return invalid() }
        return MainActor.assumeIsolated {
            guard let store = AccountController.shared.localDataAccount?.localStorage else {
                return failure("no_account")
            }
            guard let model = store.getTab(by: guid),
                  model.dataType == .bookmark || model.dataType == .bookmarkFolder,
                  model.parent != nil,
                  let profileId = model.profileId else {
                return failure("unknown_bookmark")
            }
            if let parentGuid = obj["parentGuid"] as? String {
                guard parentGuid != guid,
                      let parent = store.fetchBookmark(with: parentGuid),
                      parent.dataType == .bookmarkFolder else {
                    return failure("unknown_folder")
                }
            }
            store.moveBookmark(guid,
                               profileId: profileId,
                               to: obj["parentGuid"] as? String,
                               newIndex: (obj["index"] as? NSNumber)?.intValue ?? Int.max)
            return encode(["ok": true, "spaceId": model.spaceId ?? LocalStore.defaultSpaceId])
        }
    }

    /// `agentSpace.bookmarks.remove` — delete a bookmark, or a folder with
    /// everything in it.
    static func handleBookmarksRemove(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let guid = obj["guid"] as? String else { return invalid() }
        return MainActor.assumeIsolated {
            guard let store = AccountController.shared.localDataAccount?.localStorage else {
                return failure("no_account")
            }
            guard let model = store.getTab(by: guid),
                  model.dataType == .bookmark || model.dataType == .bookmarkFolder,
                  model.parent != nil,
                  let profileId = model.profileId else {
                return failure("unknown_bookmark")
            }
            store.deleteBookmark(guid, profileId: profileId)
            return encode(["ok": true, "spaceId": model.spaceId ?? LocalStore.defaultSpaceId])
        }
    }

    // MARK: - Downloads

    /// Serializes one Chromium download item into the agent-facing shape.
    /// `state` is normalized to a wire string; times are ms-since-epoch (start
    /// is always set once known, `endTime` is 0 until the item finishes).
    @MainActor
    private static func downloadDict(_ item: DownloadItemWrapper) -> [String: Any] {
        let state: String
        switch item.state {
        case 0: state = "in_progress"
        case 1: state = "complete"
        case 2: state = "cancelled"
        case 3: state = "interrupted"
        default: state = "unknown"
        }
        return [
            "guid": item.guid,
            "url": item.url,
            "filename": item.fileNameToReportUser,
            "mimeType": item.mimeType,
            "state": state,
            "paused": item.isPaused,
            "done": item.isDone,
            "canResume": item.canResume,
            "totalBytes": item.totalBytes,
            "receivedBytes": item.receivedBytes,
            "percentComplete": item.percentComplete,
            "currentSpeed": item.currentSpeed,
            "startTime": item.startTime,
            "endTime": item.endTime,
            "targetPath": item.targetFilePath,
            "currentPath": item.currentPath,
            "dangerous": item.isDangerous,
            "insecure": item.isInsecure,
        ]
    }

    /// Shared body for the download control actions (pause/resume/cancel/
    /// remove): routes to the target window like every layout op, resolves the
    /// bridge, and runs `perform`. The control is asynchronous inside Chromium,
    /// so the reply only echoes the guid — poll `downloads.get` for new state.
    private static func downloadAction(
        context: ExtensionMessageContext,
        _ perform: @MainActor (any PhiChromiumBridgeProtocol, String, Int64) -> Void
    ) -> String? {
        guard let obj = json(context.payload),
              let guid = obj["guid"] as? String else { return invalid() }
        return withLayoutWindow(obj, context: context) { target in
            guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
                return failure("bridge_unavailable")
            }
            perform(bridge, guid, Int64(target.windowId))
            return encode(["ok": true, "guid": guid])
        }
    }

    /// `agentSpace.downloads.list` — the target window's profile downloads
    /// (downloads are per-profile, shared by every Space of that profile),
    /// newest first.
    static func handleDownloadsList(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload) else { return invalid() }
        return withLayoutWindow(obj, context: context) { target in
            guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
                return failure("bridge_unavailable")
            }
            let items = bridge.getAllDownloadItems(withWindowId: Int64(target.windowId))
                .sorted { $0.startTime > $1.startTime }
                .map { downloadDict($0) }
            return encode(["ok": true, "downloads": items])
        }
    }

    /// `agentSpace.downloads.get` — a single download by `guid`.
    static func handleDownloadsGet(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload),
              let guid = obj["guid"] as? String else { return invalid() }
        return withLayoutWindow(obj, context: context) { target in
            guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
                return failure("bridge_unavailable")
            }
            guard let item = bridge.getDownloadItem(withGuid: guid,
                                                    windowId: Int64(target.windowId)) else {
                return failure("unknown_download")
            }
            return encode(["ok": true, "download": downloadDict(item)])
        }
    }

    /// `agentSpace.downloads.pause` — pause an in-progress download.
    static func handleDownloadsPause(context: ExtensionMessageContext) -> String? {
        downloadAction(context: context) { bridge, guid, windowId in
            bridge.pauseDownload(withGuid: guid, windowId: windowId)
        }
    }

    /// `agentSpace.downloads.resume` — resume a paused/interrupted download.
    static func handleDownloadsResume(context: ExtensionMessageContext) -> String? {
        downloadAction(context: context) { bridge, guid, windowId in
            bridge.resumeDownload(withGuid: guid, windowId: windowId)
        }
    }

    /// `agentSpace.downloads.cancel` — cancel an in-progress download.
    static func handleDownloadsCancel(context: ExtensionMessageContext) -> String? {
        downloadAction(context: context) { bridge, guid, windowId in
            bridge.cancelDownload(withGuid: guid, windowId: windowId)
        }
    }

    /// `agentSpace.downloads.remove` — drop a download from the list. Does not
    /// delete the file on disk.
    static func handleDownloadsRemove(context: ExtensionMessageContext) -> String? {
        downloadAction(context: context) { bridge, guid, windowId in
            bridge.removeDownload(withGuid: guid, windowId: windowId)
        }
    }
}
