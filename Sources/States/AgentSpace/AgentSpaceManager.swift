// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import Foundation

/// Ownership of an agent Space's window at any moment: the agent is driving it,
/// or the user has taken control (agent commands are rejected until hand-back).
enum AgentTaskOwnership {
    case agent
    case user
}

/// Where an agent task is driven from. `.phiAgent` tasks are orchestrated by
/// the phi-agent backend (Kensington extension origin) and participate in its
/// HTTP ownership handshake; `.cdp` tasks are driven by an external CDP client
/// (e.g. the Claude Code skill) and must never block on phi-agent HTTP.
enum AgentTaskOrigin {
    case phiAgent
    case cdp
}

/// Lifecycle state of an agent task, surfaced as a badge on the Space pip.
/// `.running` vs `.idle` is driver-reported (the CDP skill flips it: running
/// while a heredoc executes, idle between rounds).
enum AgentTaskStatus: Equatable {
    case starting
    case running
    case idle
    case completed
    case failed(message: String)
}

/// Runtime record for one agent task. Durable task state lives with the task's
/// driver (phi-agent, or the CDP client); the only persisted artifact on the
/// Swift side is the SpaceModel row, which is an ordinary user Space.
struct AgentTask {
    let taskId: String
    let spaceId: String
    let profileId: String
    let origin: AgentTaskOrigin
    /// Small, stable ordinal (1, 2, 3…) shown as a corner badge so several live
    /// agent Spaces can be told apart at a glance. Assigned at creation as the
    /// lowest number not currently in use, so it's reused after a Space closes.
    let number: Int
    var windowId: Int
    var ownership: AgentTaskOwnership
    var status: AgentTaskStatus
    var statusCaption: String
    var cursor: CGPoint?
    var cursorTabId: Int?
    var hasUnseenError: Bool
    /// The tab currently wearing the operating overlay (the mask AI chat shows
    /// when it drives a tab). Tracked so ownership flips and completion can
    /// clear it. `nil` when no tab is masked.
    var maskedTabId: Int? = nil
}

/// App-scoped owner of agent-task state. Window lifecycle stays in
/// `SpaceWindowSlot`; the Space list stays in `SpaceManager`. This module only
/// owns the mapping from an agent Space to its live task and drives the
/// ownership handshake across the three channels (Chromium agent-mode flag,
/// extension broadcast, phi-agent HTTP — the last one for `.phiAgent` tasks
/// only).
@MainActor
final class AgentSpaceManager: ObservableObject {
    static let shared = AgentSpaceManager()

    /// Visual signature every agent Space is created with. Used both at
    /// creation and by `SpaceManager`'s orphan sweep to recognize an agent
    /// Space that outlived its (in-memory) task — e.g. one persisted across a
    /// relaunch. Kept here so the two sites can never drift.
    /// Display-name prefix; the full name is the prefix plus the Space's ordinal
    /// (R1, R2, …). Also part of the signature the orphan sweep matches on.
    static let spaceNamePrefix = "R"
    // Robot emoji (🤖) from the emoji catalog — see Resources/Emoji/emoji-catalog.json.
    static let spaceIconName = "emoji:1F916"
    static let spaceColorHex = "#8E8E93"

    /// An agent Space's display name for its ordinal — "R1", "R2", …
    static func agentSpaceName(_ number: Int) -> String { "\(spaceNamePrefix)\(number)" }

    /// True if `name` looks like an agent Space's ordinal name (the prefix
    /// followed by one or more digits).
    nonisolated static func isAgentSpaceName(_ name: String) -> Bool {
        guard name.hasPrefix(spaceNamePrefix) else { return false }
        let rest = name.dropFirst(spaceNamePrefix.count)
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }

    /// True if `space` looks like an agent Space (created by `createAgentSpace`).
    /// Pure/`nonisolated` so the Space-list sweep can call it off the main actor.
    nonisolated static func isAgentSpaceModel(name: String, iconName: String, colorHex: String) -> Bool {
        isAgentSpaceName(name) && iconName == spaceIconName && colorHex == spaceColorHex
    }

    @Published private(set) var tasksBySpaceId: [String: AgentTask] = [:]

    private var spaceIdByTaskId: [String: String] = [:]

    private init() {}

    // MARK: - Queries

    func isAgentSpace(_ spaceId: String) -> Bool {
        tasksBySpaceId[spaceId] != nil
    }

    func isAgentOwned(_ spaceId: String) -> Bool {
        tasksBySpaceId[spaceId]?.ownership == .agent
    }

    /// Lowest positive ordinal not currently worn by a live agent Space, so
    /// concurrent Spaces read 1, 2, 3… and a number frees up when its Space ends.
    private func nextAgentNumber() -> Int {
        let used = Set(tasksBySpaceId.values.map(\.number))
        var n = 1
        while used.contains(n) { n += 1 }
        return n
    }

    func task(forSpaceId spaceId: String) -> AgentTask? {
        tasksBySpaceId[spaceId]
    }

    func task(forTaskId taskId: String) -> AgentTask? {
        guard let spaceId = spaceIdByTaskId[taskId] else { return nil }
        return tasksBySpaceId[spaceId]
    }

    // MARK: - Creation

    /// Resolves the profile (by id, then display name), creates a hidden Space
    /// bound to it, spawns its window without surfacing it, and records the
    /// task. `completion` receives `(spaceId, windowId)` or nil on failure.
    func createAgentSpace(
        taskId: String,
        profileName: String,
        origin: AgentTaskOrigin = .phiAgent,
        completion: @escaping (_ spaceId: String?, _ windowId: Int?) -> Void
    ) {
        if let existingSpaceId = spaceIdByTaskId[taskId] {
            guard let existing = tasksBySpaceId[existingSpaceId],
                  existing.origin == origin else {
                // A different driver owns this taskId. Reveal nothing about its
                // Space — the same "as if it doesn't exist" boundary the control
                // handlers draw — and fail the create instead of sharing ids.
                AppLogWarn("[AgentSpace] createAgentSpace: taskId \(taskId) belongs to another origin")
                completion(nil, nil)
                return
            }
            guard existing.windowId != 0 else {
                // A concurrent create is still spawning the window. Returning
                // windowId 0 would poison every windowId-scoped call the caller
                // makes this round — fail cleanly and let it retry.
                AppLogWarn("[AgentSpace] createAgentSpace: taskId \(taskId) is still spawning")
                completion(nil, nil)
                return
            }
            AppLogWarn("[AgentSpace] createAgentSpace: taskId \(taskId) already exists")
            completion(existingSpaceId, existing.windowId)
            return
        }
        // The cached profile list is empty when ProfileManager's init ran
        // before the Chromium bridge was up and no profile UI has refreshed it
        // since; a headless CDP create can't rely on UI having run, so refresh
        // here (same pattern as ProfileManager's own mutations).
        ProfileManager.shared.refresh()
        let profiles = ProfileManager.shared.profiles
        let resolved =
            profiles.first(where: { $0.profileId == profileName })
            ?? profiles.first(where: { $0.displayName == profileName })
            ?? (profileName.isEmpty ? profiles.first : nil)
        guard let profile = resolved else {
            AppLogWarn("[AgentSpace] createAgentSpace: no profile matching '\(profileName)'")
            completion(nil, nil)
            return
        }

        // Ordinal picked up front so the Space name (R1, R2, …) and the task's
        // badge number are the same value.
        let number = nextAgentNumber()
        guard let spaceId = SpaceManager.shared.createSpace(
            name: Self.agentSpaceName(number),
            colorHex: Self.spaceColorHex,
            iconName: Self.spaceIconName,
            profileId: profile.profileId,
            makeDefaultActive: false
        ) else {
            AppLogWarn("[AgentSpace] createAgentSpace: createSpace failed")
            completion(nil, nil)
            return
        }

        // Record the task now (ownership=agent, starting) so isAgentSpace() is
        // true before the coordinator's window-created callback runs.
        tasksBySpaceId[spaceId] = AgentTask(
            taskId: taskId,
            spaceId: spaceId,
            profileId: profile.profileId,
            origin: origin,
            number: number,
            windowId: 0,
            ownership: .agent,
            status: .starting,
            statusCaption: "",
            cursor: nil,
            cursorTabId: nil,
            hasUnseenError: false
        )
        spaceIdByTaskId[taskId] = spaceId

        guard let slot = SpaceManager.shared.keySlot ?? SpaceManager.shared.slots.first else {
            // No window open at all — the persisted-active Space hasn't been
            // surfaced. v1: fail cleanly; the caller retries once a window is up.
            AppLogWarn("[AgentSpace] createAgentSpace: no slot available to spawn into")
            tasksBySpaceId[spaceId] = nil
            spaceIdByTaskId[taskId] = nil
            SpaceManager.shared.deleteSpace(spaceId: spaceId)
            completion(nil, nil)
            return
        }

        slot.spawnHiddenWindow(forSpaceId: spaceId) { [weak self] windowId in
            guard let self else { completion(nil, nil); return }
            guard let windowId else {
                self.tasksBySpaceId[spaceId] = nil
                self.spaceIdByTaskId[taskId] = nil
                SpaceManager.shared.deleteSpace(spaceId: spaceId)
                completion(nil, nil)
                return
            }
            if var task = self.tasksBySpaceId[spaceId] {
                task.windowId = windowId
                task.status = .running
                self.tasksBySpaceId[spaceId] = task
            }
            completion(spaceId, windowId)
        }
    }

    // MARK: - Ownership handshake

    /// The user switched into the agent Space's window (watch mode). Ownership
    /// stays with the agent; clear any unseen-error badge.
    func userDidSurface(spaceId: String) {
        guard var task = tasksBySpaceId[spaceId] else { return }
        task.hasUnseenError = false
        tasksBySpaceId[spaceId] = task
        guard task.origin == .phiAgent else { return }
        // Presence is informational; fire-and-forget.
        let taskId = task.taskId
        Task { try? await APIClient.shared.setAgentSpacePresence(taskId: taskId, userPresent: true) }
    }

    /// The user switched away from the agent Space's window. Ordering the
    /// window out makes macOS occlusion mark its WebContents hidden, and the
    /// one-shot visibility forcing in Chromium only re-fires on tab insertion
    /// or active-tab change — so re-assert agent mode shortly after the swap to
    /// keep the agent's renderer painting off screen.
    func userDidLeave(spaceId: String) {
        guard let task = tasksBySpaceId[spaceId], task.ownership == .agent,
              task.windowId != 0 else { return }
        let windowId = task.windowId
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self,
                  let current = self.tasksBySpaceId[spaceId],
                  current.ownership == .agent, current.windowId == windowId else { return }
            ChromiumLauncher.sharedInstance().bridge?
                .setAgentMode(true, windowId: Int64(windowId))
        }
    }

    /// The user takes control (interrupt). Order: synchronous Chromium flag →
    /// extension broadcast → phi-agent HTTP (`.phiAgent` tasks only). Local
    /// state stays `.user` even if the HTTP call fails (local enforcement
    /// already holds).
    func takeControl(spaceId: String) {
        guard var task = tasksBySpaceId[spaceId] else { return }
        task.ownership = .user
        tasksBySpaceId[spaceId] = task
        // The user is driving now — drop the operating mask.
        refreshOperatingMask(forSpaceId: spaceId,
                             activeTabId: currentActiveTabId(forSpaceId: spaceId))

        ChromiumLauncher.sharedInstance().bridge?
            .setAgentMode(false, windowId: Int64(task.windowId))
        broadcastOwnership(taskId: task.taskId, owner: "user")
        guard task.origin == .phiAgent else { return }
        let taskId = task.taskId
        Task {
            try? await APIClient.shared.handoffAgentSpace(taskId: taskId, reason: "user_interrupt")
        }
    }

    /// The agent asked to give control to the user (e.g. login or captcha).
    /// Same state transition as a user interrupt; the caller (the agent) is
    /// the one requesting it, so no phi-agent notification fires here for
    /// `.cdp` tasks either way. `message` — what the agent needs the user to do
    /// — is surfaced in a prompt with a shortcut to switch into the Space.
    func interruptByAgentRequest(taskId: String, message: String? = nil) -> Bool {
        guard let spaceId = spaceIdByTaskId[taskId] else { return false }
        takeControl(spaceId: spaceId)
        presentHandoffPrompt(spaceId: spaceId, message: message)
        return true
    }

    /// Prompts the user that the agent needs them, showing the agent's message
    /// and a one-click switch into the agent Space to finish the step. Shown as
    /// a sheet on the key window (non-blocking) so the user can act when ready.
    private func presentHandoffPrompt(spaceId: String, message: String?) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "The agent needs you", comment: "Agent handoff prompt - title")
        alert.informativeText = (message?.isEmpty == false)
            ? message!
            : NSLocalizedString(
                "The agent handed control back to you to finish a step — for example, signing in.",
                comment: "Agent handoff prompt - default body")
        alert.addButton(withTitle: NSLocalizedString(
            "Switch to Agent Space", comment: "Agent handoff prompt - open the agent Space"))
        alert.addButton(withTitle: NSLocalizedString(
            "Later", comment: "Agent handoff prompt - dismiss"))
        let switchToSpace = {
            SpaceManager.shared.activateInFocusedWindow(spaceId: spaceId)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { switchToSpace() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            switchToSpace()
        }
    }

    /// The user hands control back to the agent. For `.phiAgent` tasks the
    /// backend must accept before the agent resumes, so the HTTP call goes
    /// first. `.cdp` tasks flip locally and synchronously — the CDP client
    /// observes the ownership broadcast and resumes on its own.
    func handBack(spaceId: String) {
        guard let task = tasksBySpaceId[spaceId] else { return }
        let taskId = task.taskId
        let windowId = task.windowId

        if task.origin == .cdp {
            var t = task
            t.ownership = .agent
            tasksBySpaceId[spaceId] = t
            refreshOperatingMask(forSpaceId: spaceId,
                                 activeTabId: currentActiveTabId(forSpaceId: spaceId))
            ChromiumLauncher.sharedInstance().bridge?
                .setAgentMode(true, windowId: Int64(windowId))
            broadcastOwnership(taskId: taskId, owner: "agent")
            return
        }

        Task { [weak self] in
            do {
                try await APIClient.shared.setAgentSpacePresence(
                    taskId: taskId, userPresent: false, handback: true)
            } catch {
                AppLogWarn("[AgentSpace] handBack: phi-agent rejected, not resuming agent")
                return
            }
            await MainActor.run {
                guard let self, var t = self.tasksBySpaceId[spaceId] else { return }
                t.ownership = .agent
                self.tasksBySpaceId[spaceId] = t
                self.refreshOperatingMask(forSpaceId: spaceId,
                                          activeTabId: self.currentActiveTabId(forSpaceId: spaceId))
                ChromiumLauncher.sharedInstance().bridge?
                    .setAgentMode(true, windowId: Int64(windowId))
                self.broadcastOwnership(taskId: taskId, owner: "agent")
            }
        }
    }

    /// The agent resumes control after the user explicitly confirmed (the CDP
    /// client's takeover, mirroring ego's semantics — policy enforcement lives
    /// in the client). Flips locally; no phi-agent involvement.
    func resumeAgentControl(taskId: String) -> Bool {
        guard let spaceId = spaceIdByTaskId[taskId],
              var task = tasksBySpaceId[spaceId] else { return false }
        guard task.ownership == .user else { return true }
        task.ownership = .agent
        tasksBySpaceId[spaceId] = task
        refreshOperatingMask(forSpaceId: spaceId,
                             activeTabId: currentActiveTabId(forSpaceId: spaceId))
        ChromiumLauncher.sharedInstance().bridge?
            .setAgentMode(true, windowId: Int64(task.windowId))
        broadcastOwnership(taskId: taskId, owner: "agent")
        return true
    }

    // MARK: - State / completion (inbound from the agent)

    func setStatusCaption(taskId: String, caption: String) {
        guard let spaceId = spaceIdByTaskId[taskId], var task = tasksBySpaceId[spaceId] else { return }
        task.statusCaption = caption
        tasksBySpaceId[spaceId] = task
    }

    /// Driver-reported activity for the pip badge: `.running` while the agent is
    /// executing a step, `.idle` between steps. Never overrides a terminal state
    /// (`.completed`/`.failed`) — those own the pip until the Space is cleaned up.
    func setRunState(taskId: String, running: Bool) {
        guard let spaceId = spaceIdByTaskId[taskId], var task = tasksBySpaceId[spaceId] else { return }
        switch task.status {
        case .completed, .failed:
            return
        case .starting, .running, .idle:
            task.status = running ? .running : .idle
            tasksBySpaceId[spaceId] = task
        }
    }

    func setCursor(taskId: String, tabId: Int, point: CGPoint) {
        guard let spaceId = spaceIdByTaskId[taskId], var task = tasksBySpaceId[spaceId] else { return }
        task.cursor = point
        task.cursorTabId = tabId
        tasksBySpaceId[spaceId] = task
    }

    func markError(taskId: String, message: String) {
        guard let spaceId = spaceIdByTaskId[taskId], var task = tasksBySpaceId[spaceId] else { return }
        task.status = .failed(message: message)
        task.hasUnseenError = true
        tasksBySpaceId[spaceId] = task
    }

    /// Task finished. Agent Spaces are ephemeral — they exist only while their
    /// task is running, so completion always flips agent mode off, drops the
    /// task record, and deletes the Space (closing its window). The `keep` flag
    /// is accepted for protocol compatibility but no longer leaves a lingering
    /// Space; a finished agent Space is never kept in the switcher.
    func taskDidComplete(taskId: String, success: Bool, keep: Bool, message: String? = nil) {
        guard let spaceId = spaceIdByTaskId[taskId], let task = tasksBySpaceId[spaceId] else { return }
        // The Space is removed either way; keep the driver-reported outcome
        // observable in the log (there is no surviving UI to show it on).
        AppLogInfo("[AgentSpace] task \(taskId) completed success=\(success)"
            + (message.map { " message=\($0)" } ?? ""))
        if let masked = task.maskedTabId {
            AgentAnimationManager.shared.setActive(false, for: masked)
        }
        ChromiumLauncher.sharedInstance().bridge?
            .setAgentMode(false, windowId: Int64(task.windowId))
        tasksBySpaceId[spaceId] = nil
        spaceIdByTaskId[taskId] = nil
        SpaceManager.shared.deleteSpace(spaceId: spaceId)
    }

    /// The Space was deleted out from under its live task (a user delete from
    /// the switcher/strip). Drop the task record and its overlay side effects
    /// immediately so no stale record lingers for stateless CDP clients to
    /// keep "finding" — the window itself is torn down by the deletion, so no
    /// agent-mode flip is needed. Called by `SpaceManager.deleteSpace`; a
    /// completion-driven delete is a no-op here because `taskDidComplete`
    /// already removed the record.
    func spaceWasDeleted(spaceId: String) {
        guard let task = tasksBySpaceId[spaceId] else { return }
        if let masked = task.maskedTabId {
            AgentAnimationManager.shared.setActive(false, for: masked)
        }
        tasksBySpaceId[spaceId] = nil
        spaceIdByTaskId[task.taskId] = nil
    }

    // MARK: - Operating-tab mask

    /// Mirrors the agent's operating (active) tab with the same overlay AI chat
    /// shows when it drives a tab (`AgentAnimationManager` → the edge-fog mask).
    /// While the agent holds control, `activeTabId` wears the mask; otherwise
    /// (user in control, or no active tab) it is cleared. Any previously masked
    /// tab in this Space is cleared first, so exactly one tab is masked. Driven
    /// from `BrowserState.focuseTab` (active-tab change) and the ownership flips.
    func refreshOperatingMask(forSpaceId spaceId: String, activeTabId: Int?) {
        guard var task = tasksBySpaceId[spaceId] else { return }
        let newMasked = task.ownership == .agent ? activeTabId : nil
        guard task.maskedTabId != newMasked else { return }
        if let old = task.maskedTabId {
            AgentAnimationManager.shared.setActive(false, for: old)
        }
        if let newMasked {
            AgentAnimationManager.shared.setActive(true, for: newMasked)
        }
        task.maskedTabId = newMasked
        tasksBySpaceId[spaceId] = task
    }

    /// The Phi tab id of the agent window's currently active (operating) tab.
    private func currentActiveTabId(forSpaceId spaceId: String) -> Int? {
        guard let task = tasksBySpaceId[spaceId], task.windowId != 0 else { return nil }
        return MainBrowserWindowControllersManager.shared
            .getBrowserState(for: task.windowId)?.focusingTab?.guid
    }

    // MARK: - Helpers

    func ownership(forTaskId taskId: String) -> AgentTaskOwnership? {
        guard let spaceId = spaceIdByTaskId[taskId] else { return nil }
        return tasksBySpaceId[spaceId]?.ownership
    }

    /// Which driver owns this task. Used to scope inbound control messages to
    /// their own origin so a CDP client can't drive a phi-agent Space (or vice
    /// versa) just by naming its taskId.
    func origin(forTaskId taskId: String) -> AgentTaskOrigin? {
        guard let spaceId = spaceIdByTaskId[taskId] else { return nil }
        return tasksBySpaceId[spaceId]?.origin
    }

    private func broadcastOwnership(taskId: String, owner: String) {
        // taskId is caller-chosen (an LLM-authored task name can contain quotes)
        // — serialize, never interpolate into JSON.
        guard let data = try? JSONSerialization.data(
                withJSONObject: ["taskId": taskId, "owner": owner]),
              let payload = String(data: data, encoding: .utf8) else { return }
        ExtensionMessaging.shared.broadcast(type: "agentSpace.ownershipChanged", payload: payload)
    }
}

extension SpaceModel {
    /// True when this Space is an agent Space created by `AgentSpaceManager`,
    /// matched by its visual signature. Used to hide agent Spaces from the
    /// settings surfaces they don't belong in (the Space list, URL-rule routing
    /// targets); both a live agent Space and a not-yet-swept orphan match.
    var isAgentSpace: Bool {
        AgentSpaceManager.isAgentSpaceModel(
            name: name, iconName: iconName, colorHex: colorHex)
    }
}
