// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import Foundation
import PostHog
import SwiftUI

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
    /// Owning logical external-agent session. Required for `.cdp` tasks and
    /// nil for the in-app `.phiAgent` backend. This is authorization state;
    /// `agentName` below is presentation only. Mutable for exactly one flow:
    /// a restarted agent re-adopting its own task once the original owning
    /// process is gone (see `createAgentSpace`).
    var driverPrincipalId: String?
    /// Small, stable ordinal (1, 2, 3…) shown as a corner badge so several live
    /// agent Spaces can be told apart at a glance. Assigned at creation as the
    /// lowest number not currently in use, so it's reused after a Space closes.
    let number: Int
    var windowId: Int
    var ownership: AgentTaskOwnership
    var status: AgentTaskStatus
    var statusCaption: String
    /// Display conduit only: the manager keeps live cursor state in
    /// `cursorBySpaceId` (streamed via `cursorMoved`); mounters copy it in
    /// here — converted to view coordinates — right before handing the task
    /// to their overlay's `update(with:)`.
    var cursor: CGPoint?
    var hasUnseenError: Bool
    /// The tab currently wearing the operating overlay (the mask AI chat shows
    /// when it drives a tab). Tracked so ownership flips and completion can
    /// clear it. `nil` when no tab is masked.
    var maskedTabId: Int? = nil
    /// When the task expires if the agent stays silent (see the keep-alive
    /// sweep in `AgentSpaceManager`). Refreshed by every control message from
    /// the owning driver; `agentSpace.ping` sets it explicitly. Ignored while
    /// the user holds control.
    var keepAliveDeadline: Date = .distantFuture
    /// A persistent task's Space is a permanent workspace: exempt from the
    /// keep-alive sweep, kept on completion (window closed, Space row intact),
    /// and recognizable on disk across relaunches
    /// (`isPersistentAgentSpaceModel` + name == taskId) so a later task with
    /// the same taskId re-binds to it instead of creating a duplicate.
    var persistent: Bool = false
    /// The code agent driving this Space, as resolved from the CDP
    /// connection's authenticated identity (the signing identifier or process
    /// name — e.g. "Claude Code", "Codex", or the terminal that launched it).
    /// Empty for phi-agent tasks and when the identity couldn't be resolved.
    /// Surfaced as a badge on the control pill and the transcript filter.
    var agentName: String = ""
}

/// Presentation for "which code agent drives this Space": an icon plus a short
/// label, derived from the task's resolved driver identity. `assetName` is a
/// bundled brand icon (template imageset under Assets ▸ agents) when the agent
/// is recognized; otherwise `symbol` is an SF Symbol fallback. Kept
/// framework-neutral so both the AppKit control pill and the SwiftUI transcript
/// panel render it. Best-effort — the ancestry-based identity often resolves to
/// the launching terminal, so unknown drivers fall back to a generic glyph.
struct AgentDriverBadge {
    /// A bundled template imageset name, or nil to use `symbol`.
    let assetName: String?
    /// SF Symbol fallback, used when `assetName` is nil.
    let symbol: String
    let label: String

    /// The agent imagesets are normalized so every glyph's ink spans 42px of
    /// the 54px canvas (equal optical size across brands). A view that fits
    /// the CANVAS to a slot therefore renders the ink at 78% of it — visibly
    /// smaller than an SF Symbol in the same slot. Views mixing both divide
    /// their slot size by this ratio for the asset case, so the ink — not the
    /// canvas — matches the neighbors.
    static let assetInkRatio: CGFloat = 42.0 / 54.0

    /// The browser's own mark, worn by the built-in agent. The other entries
    /// here badge an OUTSIDE product driving Phi; this one is Phi driving
    /// itself, so it shows the product's own glyph rather than a third-party
    /// brand or a generic terminal. Normalized to `assetInkRatio` like the
    /// rest, so it sits at the same optical size beside them.
    static let phiBrandAssetName = "agent-phi"

    static func make(agentName: String, origin: AgentTaskOrigin) -> AgentDriverBadge {
        if origin == .phiAgent {
            return AgentDriverBadge(assetName: phiBrandAssetName,
                                    symbol: "sparkles", label: "Phi")
        }
        let lower = agentName.lowercased()
        // The same agent reached by NAME rather than by origin. `origin` is
        // `.phiAgent` only where the app already knows — a task it opened
        // itself, or a drive the verified first-party pass decided. A drive
        // the browser reports on its own arrives named after whatever the
        // ancestry walk resolved, which for this component is its script:
        // "phi-agent.bundle". Left to fall through, `friendlyName` keeps only
        // the text after the last dot and the pill reads "bundle".
        //
        // This is a LABEL, not a permission: nothing here decides access, and
        // Phi-signed code that fails the first-party checks is refused before
        // it can drive anything (see AgentIdentity.unresolvedOwnCode). The
        // consent prompt, which is where trust is actually placed, keeps
        // showing the real command and signature.
        if Self.namesPhiAgent(lower) {
            return AgentDriverBadge(assetName: phiBrandAssetName,
                                    symbol: "sparkles", label: "Phi")
        }
        if lower.contains("claude") {
            return AgentDriverBadge(assetName: "agent-claude",
                                    symbol: "chevron.left.forwardslash.chevron.right",
                                    label: "Claude Code")
        }
        // "chatgpt": Codex run inside the ChatGPT desktop app resolves to the
        // bundled binary, whose display name is the OUTER bundle's ("ChatGPT",
        // not its signing id "codex" — see AgentPeerIdentity.signingIdentity).
        if lower.contains("codex") || lower.contains("openai") || lower.contains("chatgpt") {
            return AgentDriverBadge(assetName: "agent-openai",
                                    symbol: "chevron.left.forwardslash.chevron.right",
                                    label: "Codex")
        }
        if lower.contains("openclaw") {
            return AgentDriverBadge(assetName: "agent-openclaw",
                                    symbol: "chevron.left.forwardslash.chevron.right",
                                    label: "OpenClaw")
        }
        if lower.contains("hermes") {
            return AgentDriverBadge(assetName: "agent-hermes",
                                    symbol: "chevron.left.forwardslash.chevron.right",
                                    label: "Hermes")
        }
        if lower.contains("cursor") {
            return AgentDriverBadge(assetName: "agent-cursor",
                                    symbol: "chevron.left.forwardslash.chevron.right",
                                    label: "Cursor")
        }
        // "pi" is a short token — match it precisely so it doesn't collide with
        // unrelated identities (api, raspberry, …).
        if lower == "pi" || lower.hasPrefix("pi.") || lower.hasPrefix("pi-")
            || lower.contains("pi.dev") || lower.contains(".pi.") {
            return AgentDriverBadge(assetName: "agent-pi",
                                    symbol: "chevron.left.forwardslash.chevron.right",
                                    label: "Pi")
        }
        // A recognizable terminal is still useful context (that's who launched
        // the agent); otherwise show whatever name resolved, or a generic tag.
        let friendly = Self.friendlyName(agentName)
        return AgentDriverBadge(
            assetName: nil,
            symbol: "terminal",
            label: friendly.isEmpty ? "Code agent" : friendly)
    }

    /// Whether a resolved driver name is the browser's own agent: the product
    /// name itself, or the phi-agent component as a whole dot-separated
    /// segment — "phi-agent", and "phi-agent.bundle" as the ancestry walk
    /// derives it from the script. Compared by SEGMENT rather than by
    /// substring, so a name that merely contains the text ("not-phi-agentx")
    /// is not mistaken for it, and so the sibling "pi-agent" — a different
    /// product, and an outside agent here — keeps its own badge below.
    private static func namesPhiAgent(_ lowercasedName: String) -> Bool {
        if lowercasedName == AgentPeerIdentity.firstPartyDisplayName.lowercased() {
            return true
        }
        return lowercasedName.split(separator: ".")
            .contains(Substring(AgentPeerIdentity.phiAgentComponentName))
    }

    /// Telemetry-safe agent label: the canonical product name when the
    /// identity matches a known agent brand, else "other" ("unknown" when
    /// empty). Never the raw identity string — for unsigned scripts that is
    /// derived from a local file path (see AgentPeerIdentity.deriveAgentName)
    /// and must not reach analytics.
    static func telemetryName(_ agentName: String) -> String {
        guard !agentName.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "unknown"
        }
        let badge = make(agentName: agentName, origin: .cdp)
        return badge.assetName != nil ? badge.label : "other"
    }

    /// Reduces a signing identifier / bundle id to a readable label —
    /// "com.apple.Terminal" → "Terminal", "com.googlecode.iterm2" → "iterm2".
    private static func friendlyName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "Unknown process" else { return "" }
        if let last = trimmed.split(separator: ".").last, trimmed.contains(".") {
            return String(last)
        }
        return trimmed
    }
}

/// A transient visual mirror of one agent input action (a click, typing into
/// a field, a scroll), rendered as a short animation by the Space's overlay so
/// a watching user can follow what the agent is doing. Not task state: effects
/// are fire-and-forget and never persisted, so they stream through
/// `AgentSpaceManager.effectRequested` instead of `tasksBySpaceId`.
struct AgentEffect {
    enum Kind: String {
        case click
        case type
        case scroll
    }

    let spaceId: String
    let kind: Kind
    /// Widget-space point, same coordinate space as `AgentTask.cursor`.
    /// `nil` anchors the effect on the task's last cursor position.
    let point: CGPoint?
    /// For `.type`: the focused element's widget-space size, so the overlay
    /// can outline the field being typed into.
    let size: CGSize?
    /// For `.scroll`: the wheel's deltaY — the sign gives the direction hint.
    let dy: CGFloat?
}

/// One agent-cursor position sample, streamed straight to the overlay
/// mounters like `AgentEffect`. Drivers sample cursor glides tens of times a
/// second, so cursor motion deliberately bypasses the `tasksBySpaceId`
/// publish — a full task-dictionary fan-out per sample would re-render every
/// subscriber's whole pill on the main thread for a one-layer position move.
struct AgentCursorUpdate {
    let spaceId: String
    /// Widget-space point, same coordinate space as `AgentEffect.point`.
    let point: CGPoint
}

/// A command the user typed into the agent console, waiting for the driving
/// agent to pick it up. Queued per task (the driver drains at its round
/// boundaries via `agentSpace.readUserMessages`); a broadcast wakes a live
/// round immediately, but the queue stays authoritative so a message sent
/// between rounds is never lost.
struct PendingUserMessage {
    let id: UUID
    let text: String
    let ts: Date
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
    /// Persistent agent Spaces wear the agent icon in this color and are
    /// NAMED by their taskId (no R-ordinal), so they never match the
    /// ephemeral signature: the orphan sweep spares them across relaunches,
    /// the ephemeral-Space UI filters don't hide them, and the name doubles
    /// as the durable taskId → Space mapping for re-binding.
    static let persistentSpaceColorHex = "#5856D6"

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
    /// Matches EPHEMERAL agent Spaces only — persistent ones (see
    /// `isPersistentAgentSpaceModel`) are deliberately excluded so every
    /// ephemerality consumer (orphan sweep, snapshot rewrite, UI hiding)
    /// leaves them alone.
    nonisolated static func isAgentSpaceModel(name: String, iconName: String, colorHex: String) -> Bool {
        isAgentSpaceName(name) && iconName == spaceIconName && colorHex == spaceColorHex
    }

    /// True if `space` looks like a persistent agent Space (created by
    /// `createAgentSpace(persistent: true)`). The name is not part of the
    /// match — it carries the taskId.
    nonisolated static func isPersistentAgentSpaceModel(iconName: String, colorHex: String) -> Bool {
        iconName == spaceIconName && colorHex == persistentSpaceColorHex
    }

    @Published private(set) var tasksBySpaceId: [String: AgentTask] = [:]

    /// Transient input-mirror effects (click ripple, typing pulse, scroll
    /// hint) streamed straight to the overlay mounters — see `AgentEffect`.
    let effectRequested = PassthroughSubject<AgentEffect, Never>()

    /// Live agent-cursor motion, streamed like effects — see
    /// `AgentCursorUpdate` for why it does not ride `tasksBySpaceId`.
    let cursorMoved = PassthroughSubject<AgentCursorUpdate, Never>()

    /// Last cursor point per Space, so a mounter that (re)appears mid-glide
    /// can seed the overlay without waiting for the next sample. Not
    /// `@Published`: reads ride the task publish that mounted the overlay.
    private(set) var cursorBySpaceId: [String: CGPoint] = [:]

    private var spaceIdByTaskId: [String: String] = [:]

    /// Shadow windows this manager opened, keyed by taskId. Space-less
    /// siblings of `tasksBySpaceId`: same taskId namespace, same origin/
    /// principal authorization, same keep-alive clock — but no Space, no pip
    /// and no transcript, because the window is invisible (see
    /// AgentSpaceManager+Shadow.swift). Kept here rather than in a manager of
    /// their own so agent-driven windows have exactly one owner.
    var shadowWindowsByTaskId: [String: ShadowWindow] = [:]

    /// User commands typed into the agent console, per task, until the driver
    /// drains them (`drainUserMessages`). Bounded so an unread console can't
    /// grow without limit; dropped with the task.
    private var pendingUserMessagesByTaskId: [String: [PendingUserMessage]] = [:]
    static let maxPendingUserMessages = 50
    static let maxUserMessageChars = 2000

    // MARK: - Keep-alive timeout

    /// How long a driving agent may stay silent before its Space auto-closes.
    /// Every control message refreshes the deadline by this much; the agent can
    /// buy a longer window (up to `maxKeepAliveTTL`) with `agentSpace.ping` —
    /// the skill does so when a round ends, so a task survives the gaps between
    /// heredoc rounds but an abandoned Space (crashed or killed session) still
    /// goes away instead of lingering as a stale pip until the next relaunch.
    /// A round start (`agentSpace.setState` running) resets the deadline back
    /// to this window, so a bought grace never outlives the gap it covered.
    static let defaultKeepAliveTTL: TimeInterval = 120
    /// Between-rounds grace granted on hand-back (the driving session may take
    /// a while to run its next round) — matches the skill's round-end ping.
    static let interRoundKeepAliveTTL: TimeInterval = 30 * 60
    static let maxKeepAliveTTL: TimeInterval = 60 * 60
    private static let keepAliveSweepInterval: TimeInterval = 10

    private var keepAliveSweepTimer: Timer?

    /// The floating handoff prompt (one at a time) and the Space it asks the
    /// user to visit — see `presentHandoffPrompt`.
    private var handoffPromptPanel: NSPanel?
    private var handoffPromptSpaceId: String?
    /// Dock-bounce request shown with the handoff prompt, cancelled with it —
    /// an auto-dismissed prompt (hand-back, completion) must not keep bouncing.
    private var handoffPromptAttentionRequest: Int?

    private init() {
        // The operating mask's in-page recolor differs between light and dark
        // appearance, so any theme source flipping must restyle masked pages.
        // All three notifications funnel into the same per-window re-resolve.
        for name: Notification.Name in
            [.themeDidChange, .appearanceDidChange, .spaceThemeDidChange] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshMaskedPageThemes()
                }
            }
        }
    }

    /// Refreshes `taskId`'s expiry. A plain control message never SHORTENS a
    /// window an explicit ping bought (`max` with the current deadline); an
    /// explicit `ttlSeconds` is authoritative in both directions.
    func touchKeepAlive(taskId: String, ttlSeconds: TimeInterval? = nil) {
        guard let spaceId = spaceIdByTaskId[taskId],
              var task = tasksBySpaceId[spaceId] else { return }
        // Persistent tasks never expire — even an explicit ping must not arm
        // a deadline on one (its deadline stays .distantFuture for life).
        guard !task.persistent else { return }
        if let ttl = ttlSeconds {
            let clamped = min(max(ttl, 1), Self.maxKeepAliveTTL)
            task.keepAliveDeadline = Date().addingTimeInterval(clamped)
        } else {
            task.keepAliveDeadline = max(task.keepAliveDeadline,
                                         Date().addingTimeInterval(Self.defaultKeepAliveTTL))
        }
        tasksBySpaceId[spaceId] = task
    }

    func ensureKeepAliveSweep() {
        guard keepAliveSweepTimer == nil else { return }
        let timer = Timer(timeInterval: Self.keepAliveSweepInterval, repeats: true) { _ in
            MainActor.assumeIsolated { AgentSpaceManager.shared.sweepExpiredTasks() }
        }
        keepAliveSweepTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopKeepAliveSweepIfIdle() {
        guard tasksBySpaceId.isEmpty, shadowWindowsByTaskId.isEmpty else { return }
        keepAliveSweepTimer?.invalidate()
        keepAliveSweepTimer = nil
    }

    /// Closes agent Spaces whose driver has gone silent past the deadline.
    /// Only `.cdp` tasks — phi-agent tasks have their own backend lifecycle —
    /// and only while the AGENT holds control: a Space handed to the user
    /// (login, captcha) must wait for them however long they take.
    private func sweepExpiredTasks() {
        let now = Date()
        let expired = tasksBySpaceId.values.filter {
            $0.origin == .cdp && $0.ownership == .agent && !$0.persistent
                && $0.keepAliveDeadline < now
        }
        for task in expired {
            AppLogInfo("[AgentSpace] task \(task.taskId) expired — no agent activity, auto-closing its Space")
            taskDidComplete(taskId: task.taskId, success: false, keep: false,
                            message: "expired: no agent activity")
        }
        sweepExpiredShadowWindows(now: now)
        stopKeepAliveSweepIfIdle()
    }

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

    /// Principals owning a live task — retained by the driver-session
    /// registry's prune sweep, so a dead owner's session stays resolvable
    /// (and its task adoptable) until the task itself ends. Main thread.
    var liveDriverPrincipalIds: Set<String> {
        Set(tasksBySpaceId.values.compactMap(\.driverPrincipalId))
    }

    func task(forTaskId taskId: String) -> AgentTask? {
        guard let spaceId = spaceIdByTaskId[taskId] else { return nil }
        return tasksBySpaceId[spaceId]
    }

    // MARK: - Creation

    /// Resolves the profile (by id, then display name), creates a hidden Space
    /// bound to it, spawns its window without surfacing it, and records the
    /// task. `completion` receives `(spaceId, windowId)` or nil on failure.
    ///
    /// `persistent: true` makes the Space a PERMANENT workspace: named by its
    /// taskId in the switcher, exempt from keep-alive expiry, kept on
    /// completion, and — because its signature escapes the orphan sweep —
    /// surviving relaunches. When a Space for this taskId already exists on
    /// disk, the task re-binds to it instead of creating a duplicate (the
    /// profile argument is then ignored: the Space keeps its bound profile).
    /// Outcome of resolving a create request's requested profile against the
    /// user's per-profile agent-Space permission (Settings ▸ Developer ▸ Agent
    /// permissions). `.allowed` carries the concrete profile to create in.
    enum AgentCreateProfileResolution {
        case allowed(PhiBrowserProfile)
        case blocked        // resolved to a profile the user disallows for agents
        case noMatch        // the requested profile name/id doesn't exist
        case needsTemporary // a default request, but the user left no usable
                            // profile (all disallowed, or none exist) — create one
    }

    /// Resolves a create request's profile the same way `createAgentSpace`
    /// does, then applies the permission: an explicit request for a disallowed
    /// profile is `.blocked`; an empty request picks the first profile the user
    /// still allows (so the agent's default never lands on a blocked profile),
    /// or `.blocked` when every profile is disallowed.
    @MainActor
    func resolveAgentCreateProfile(profileName: String) -> AgentCreateProfileResolution {
        ProfileManager.shared.refresh()
        let profiles = ProfileManager.shared.profiles
        if profileName.isEmpty {
            if let allowed = profiles.first(where: {
                PhiPreferences.AgentSpaces.isProfileAgentSpaceAllowed($0.profileId)
            }) {
                return .allowed(allowed)
            }
            // Nothing the agent may use — neither refuse nor fail; a dedicated
            // agent profile is created on demand (ensureAgentFallbackProfile).
            return .needsTemporary
        }
        let byId = profiles.first(where: { $0.profileId == profileName })
        let byName = profiles.first(where: { $0.displayName == profileName })
        guard let profile = byId ?? byName else {
            return .noMatch
        }
        if PhiPreferences.AgentSpaces.isProfileAgentSpaceAllowed(profile.profileId) {
            return .allowed(profile)
        }
        return .blocked
    }

    /// Resolves the agent's fallback profile for a `.needsTemporary` create,
    /// yielding its profileId. Reuses the existing fallback (matched by its
    /// reserved name or recorded id, so it isn't recreated each time),
    /// otherwise creates it under the reserved name. Deliberately not gated by
    /// the per-profile permission: this profile exists precisely because the
    /// user left the agent none it could otherwise use.
    @MainActor
    func ensureAgentFallbackProfile(completion: @escaping (String?) -> Void) {
        ProfileManager.shared.refresh()
        let reservedName = PhiPreferences.AgentSpaces.agentFallbackProfileName
        if let existing = ProfileManager.shared.profiles.first(where: {
            PhiPreferences.AgentSpaces.isAgentFallbackProfile(
                profileId: $0.profileId, displayName: $0.displayName)
        }) {
            PhiPreferences.AgentSpaces.agentFallbackProfileId = existing.profileId
            completion(existing.profileId)
            return
        }
        ProfileManager.shared.createProfile(displayName: reservedName) { newId in
            if let newId {
                PhiPreferences.AgentSpaces.agentFallbackProfileId = newId
            }
            completion(newId)
        }
    }

    func createAgentSpace(
        taskId: String,
        profileName: String,
        origin: AgentTaskOrigin = .phiAgent,
        persistent: Bool = false,
        agentName: String = "",
        driverPrincipalId: String? = nil,
        completion: @escaping (_ spaceId: String?, _ windowId: Int?) -> Void
    ) {
        if origin == .cdp {
            guard let driverPrincipalId, !driverPrincipalId.isEmpty else {
                AppLogWarn("[AgentSpace] createAgentSpace: CDP task has no driver principal")
                completion(nil, nil)
                return
            }
        }
        if let existingSpaceId = spaceIdByTaskId[taskId] {
            guard var existing = tasksBySpaceId[existingSpaceId],
                  existing.origin == origin else {
                // A different driver owns this taskId. Reveal nothing about its
                // Space — the same "as if it doesn't exist" boundary the control
                // handlers draw — and fail the create instead of sharing ids.
                AppLogWarn("[AgentSpace] createAgentSpace: taskId \(taskId) belongs to another origin")
                completion(nil, nil)
                return
            }
            if existing.driverPrincipalId != driverPrincipalId {
                // Restart recovery: a re-launched agent arrives with a fresh
                // principal but the same consent identity. It may adopt its
                // own task only once the original owning process is provably
                // gone — a LIVE owner keeps its task isolated, and the deny
                // stays indistinguishable from "no such task".
                guard origin == .cdp,
                      let taskPrincipal = existing.driverPrincipalId,
                      let callerPrincipal = driverPrincipalId,
                      AgentDriverSessionRegistry.shared.canAdopt(
                        taskPrincipalId: taskPrincipal,
                        callerPrincipalId: callerPrincipal) else {
                    AppLogWarn("[AgentSpace] createAgentSpace: taskId \(taskId) belongs to another origin")
                    completion(nil, nil)
                    return
                }
                AppLogInfo("[AgentSpace] createAgentSpace: task \(taskId) re-adopted "
                           + "by a restarted \(existing.agentName.isEmpty ? "agent" : existing.agentName)")
                existing.driverPrincipalId = callerPrincipal
                tasksBySpaceId[existingSpaceId] = existing
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
        // A persistent task re-binds to its surviving Space from an earlier
        // run — or an earlier app launch — instead of creating a duplicate:
        // matched by the persistent signature plus the name, which IS the
        // taskId.
        if persistent,
           let survivor = SpaceManager.shared.spaces.first(where: {
               Self.isPersistentAgentSpaceModel(iconName: $0.iconName, colorHex: $0.colorHex)
                   && $0.name == taskId
           }) {
            // Re-binding resumes the agent in the survivor's own profile,
            // bypassing the requested one — so honor the permission here too: a
            // profile the user has since disallowed can't be re-entered.
            guard PhiPreferences.AgentSpaces.isProfileAgentSpaceAllowed(survivor.profileId) else {
                AppLogWarn("[AgentSpace] createAgentSpace: rebind refused, profile disallowed for agents")
                completion(nil, nil)
                return
            }
            rebindPersistentSpace(taskId: taskId, spaceId: survivor.spaceId,
                                  profileId: survivor.profileId, origin: origin,
                                  agentName: agentName,
                                  driverPrincipalId: driverPrincipalId,
                                  completion: completion)
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
        // badge number are the same value. A persistent Space is named by its
        // taskId instead — the durable half of the re-bind mapping.
        let number = nextAgentNumber()
        guard let spaceId = SpaceManager.shared.createSpace(
            name: persistent ? taskId : Self.agentSpaceName(number),
            colorHex: persistent ? Self.persistentSpaceColorHex : Self.spaceColorHex,
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
            driverPrincipalId: driverPrincipalId,
            number: number,
            windowId: 0,
            ownership: .agent,
            status: .starting,
            statusCaption: "",
            cursor: nil,
            hasUnseenError: false,
            keepAliveDeadline: (origin == .cdp && !persistent)
                ? Date().addingTimeInterval(Self.defaultKeepAliveTTL)
                : .distantFuture,
            persistent: persistent,
            agentName: agentName
        )
        spaceIdByTaskId[taskId] = spaceId
        ensureKeepAliveSweep()
        beginTranscript(taskId: taskId, spaceName: Self.agentSpaceName(number))
        PostHogSDK.shared.capture("agent_task_started", properties: [
            "origin": origin == .cdp ? "cdp" : "phi_agent",
            "persistent": persistent,
            "agent_name": AgentDriverBadge.telemetryName(agentName),
        ])

        // Everything below runs against a slot; a failure at any point unwinds
        // the task recorded above with the same cleanup.
        let failSpawn: (String) -> Void = { [weak self] transcriptText in
            guard let self else { completion(nil, nil); return }
            self.appendTranscript(taskId: taskId, kind: .error, text: transcriptText)
            self.tasksBySpaceId[spaceId] = nil
            self.spaceIdByTaskId[taskId] = nil
            self.tearDownTranscript(taskId: taskId)
            SpaceManager.shared.deleteSpace(spaceId: spaceId)
            completion(nil, nil)
        }
        let spawnInto: (SpaceWindowSlot) -> Void = { [weak self] slot in
            slot.spawnHiddenWindow(forSpaceId: spaceId) { windowId in
                guard let self else { completion(nil, nil); return }
                guard let windowId else {
                    failSpawn("Task failed to start — window spawn failed")
                    return
                }
                if var task = self.tasksBySpaceId[spaceId] {
                    task.windowId = windowId
                    task.status = .running
                    self.tasksBySpaceId[spaceId] = task
                    FirstTimeActionTracker.capture(.agentTask)
                }
                completion(spaceId, windowId)
                // The task is running with a live window now — autoview may surface
                // it. Deferred a beat so the hidden spawn's window churn (key
                // suppression, re-hide) settles before the deliberate switch.
                self.autoViewReevaluate(delay: 0.8)
            }
        }

        if let slot = SpaceManager.shared.keySlot ?? SpaceManager.shared.slots.first {
            spawnInto(slot)
            return
        }
        // No window open at all — the user closed the last one with the app
        // staying in the Dock, so there is nothing to spawn into. Reopen
        // through the same path a Dock-icon click takes (persisted Space, or
        // the full session-restore replay), then spawn once its slot
        // registers. Failing here instead dead-ended every CDP round with
        // create_failed until the user surfaced a window themselves.
        guard SpaceManager.shared.reopenOnPersistedSpaceIfWindowless() else {
            AppLogWarn("[AgentSpace] createAgentSpace: no slot available to spawn into")
            failSpawn("Task failed to start — no window to spawn into")
            return
        }
        AppLogInfo("[AgentSpace] createAgentSpace: windowless — reopened the "
                   + "persisted session, waiting for its slot")
        awaitFirstSlot(deadline: Date().addingTimeInterval(Self.windowlessReopenSlotTimeout)) { slot in
            guard let slot else {
                AppLogWarn("[AgentSpace] createAgentSpace: windowless reopen "
                           + "registered no slot in time")
                failSpawn("Task failed to start — no window to spawn into")
                return
            }
            spawnInto(slot)
        }
    }

    /// How long a windowless create waits for the Dock-reopen path to register
    /// a slot before giving up — session restore settles through Chromium
    /// callbacks and can take a while on a large session.
    private static let windowlessReopenSlotTimeout: TimeInterval = 20

    /// Polls for the first registered slot until `deadline`. The reopen path
    /// creates its windows asynchronously and nothing today publishes "slot
    /// arrived"; main-queue polling serves the one caller without adding a
    /// notification channel for it.
    private func awaitFirstSlot(deadline: Date,
                                completion: @escaping (SpaceWindowSlot?) -> Void) {
        if let slot = SpaceManager.shared.keySlot ?? SpaceManager.shared.slots.first {
            completion(slot)
            return
        }
        guard Date() < deadline else {
            completion(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { completion(nil); return }
            self.awaitFirstSlot(deadline: deadline, completion: completion)
        }
    }

    /// Re-binds a persistent task to its surviving Space. Reuses a live
    /// background window when one exists — typically restored at launch from
    /// the window snapshot, adopted with its tabs by flipping it into agent
    /// mode — and spawns a fresh hidden window otherwise. Refuses while a
    /// slot has the Space ON SCREEN: the agent must not take over a window
    /// the user is looking at.
    private func rebindPersistentSpace(
        taskId: String,
        spaceId: String,
        profileId: String,
        origin: AgentTaskOrigin,
        agentName: String = "",
        driverPrincipalId: String? = nil,
        completion: @escaping (_ spaceId: String?, _ windowId: Int?) -> Void
    ) {
        func record(windowId: Int, status: AgentTaskStatus) {
            tasksBySpaceId[spaceId] = AgentTask(
                taskId: taskId,
                spaceId: spaceId,
                profileId: profileId,
                origin: origin,
                driverPrincipalId: driverPrincipalId,
                number: nextAgentNumber(),
                windowId: windowId,
                ownership: .agent,
                status: status,
                statusCaption: "",
                cursor: nil,
                hasUnseenError: false,
                keepAliveDeadline: .distantFuture,
                persistent: true,
                agentName: agentName
            )
            spaceIdByTaskId[taskId] = spaceId
            ensureKeepAliveSweep()
            beginTranscript(taskId: taskId, spaceName: taskId)
            PostHogSDK.shared.capture("agent_task_started", properties: [
                "origin": origin == .cdp ? "cdp" : "phi_agent",
                "persistent": true,
                "agent_name": AgentDriverBadge.telemetryName(agentName),
            ])
            if status == .running {
                FirstTimeActionTracker.capture(.agentTask)
            }
        }

        for slot in SpaceManager.shared.slots {
            guard let controller = slot.windowController(for: spaceId) else { continue }
            guard slot.activeSpaceId != spaceId,
                  slot.visibleController !== controller else {
                AppLogWarn("[AgentSpace] rebind \(taskId): Space is on screen — refusing to take it over")
                completion(nil, nil)
                return
            }
            let windowId = controller.windowId
            AppLogInfo("[AgentSpace] rebind \(taskId): adopting live window \(windowId) of Space \(spaceId)")
            ChromiumLauncher.sharedInstance().bridge?
                .setAgentMode(true, windowId: Int64(windowId))
            record(windowId: windowId, status: .running)
            completion(spaceId, windowId)
            autoViewReevaluate(delay: 0.8)
            return
        }

        // No live window — spawn a hidden one, same flow as a fresh create
        // but WITHOUT the delete-on-failure paths: the Space is permanent and
        // must survive a failed spawn.
        record(windowId: 0, status: .starting)
        guard let slot = SpaceManager.shared.keySlot ?? SpaceManager.shared.slots.first else {
            AppLogWarn("[AgentSpace] rebind \(taskId): no slot available to spawn into")
            appendTranscript(taskId: taskId, kind: .error,
                             text: "Task failed to start — no window to spawn into")
            tasksBySpaceId[spaceId] = nil
            spaceIdByTaskId[taskId] = nil
            tearDownTranscript(taskId: taskId)
            completion(nil, nil)
            return
        }
        slot.spawnHiddenWindow(forSpaceId: spaceId) { [weak self] windowId in
            guard let self else { completion(nil, nil); return }
            guard let windowId else {
                self.appendTranscript(taskId: taskId, kind: .error,
                                      text: "Task failed to start — window spawn failed")
                self.tasksBySpaceId[spaceId] = nil
                self.spaceIdByTaskId[taskId] = nil
                self.tearDownTranscript(taskId: taskId)
                completion(nil, nil)
                return
            }
            if var task = self.tasksBySpaceId[spaceId] {
                task.windowId = windowId
                task.status = .running
                self.tasksBySpaceId[spaceId] = task
                FirstTimeActionTracker.capture(.agentTask)
            }
            completion(spaceId, windowId)
            self.autoViewReevaluate(delay: 0.8)
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
    func takeControl(spaceId: String, initiatedByAgent: Bool = false) {
        guard var task = tasksBySpaceId[spaceId] else { return }
        task.ownership = .user
        tasksBySpaceId[spaceId] = task
        // Agent-initiated handoffs log their own richer line (with the
        // agent's message) in `interruptByAgentRequest`.
        if !initiatedByAgent {
            appendTranscript(taskId: task.taskId, kind: .status, text: "You took control")
        }
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
        AppLogInfo("[AgentSpace] agent handed control to user: task=\(taskId) spaceId=\(spaceId)")
        appendTranscript(taskId: taskId, kind: .status,
                         text: "Agent handed control to you", detail: message)
        takeControl(spaceId: spaceId, initiatedByAgent: true)
        presentHandoffPrompt(spaceId: spaceId, message: message)
        return true
    }

    /// Prompts the user that the agent needs them, showing the agent's message
    /// and a one-click switch into the agent Space to finish the step.
    ///
    /// A floating panel centered over the visible browser window — NOT a
    /// window-attached sheet: a sheet inherits its anchor window's fate, and
    /// at handoff time the window stack is churning (autoview switches, the
    /// key window can be the agent's hidden window), which stranded the
    /// prompt off-center or off-screen. The panel floats above Space swaps,
    /// always lands mid-window, and is non-blocking so the user can act when
    /// ready. Dismissed automatically when its task no longer needs the user
    /// (hand-back, takeover, completion, deletion).
    private func presentHandoffPrompt(spaceId: String, message: String?) {
        dismissHandoffPrompt()

        let body = (message?.isEmpty == false)
            ? message!
            : NSLocalizedString("agent.handoffPrompt.message", value: "The agent handed control back to you to finish a step — for example, signing in.",
                comment: "Agent handoff prompt - default body")
        let view = HandoffPromptView(
            title: NSLocalizedString("agent.handoffPrompt.title", value: "The agent needs you", comment: "Agent handoff prompt - title"),
            message: body,
            switchTitle: NSLocalizedString("agent.handoffPrompt.switchToAgentSpaceButton", value: "Switch to Agent Space", comment: "Agent handoff prompt - open the agent Space"),
            laterTitle: NSLocalizedString("agent.handoffPrompt.laterButton", value: "Later", comment: "Agent handoff prompt - dismiss"),
            onSwitch: { [weak self] in
                AppLogInfo("[AgentSpace] handoff prompt: switch to agent Space")
                self?.dismissHandoffPrompt()
                SpaceManager.shared.activateInFocusedWindow(spaceId: spaceId)
            },
            onLater: { [weak self] in
                AppLogInfo("[AgentSpace] handoff prompt: dismissed (Later)")
                self?.dismissHandoffPrompt()
            })

        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let panel = HandoffPromptPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.contentView = hosting

        // Dead center of the browser window the user is looking at; the
        // screen's center when no browser window is up.
        let slot = SpaceManager.shared.keySlot ?? SpaceManager.shared.slots.first
        let anchor = slot?.visibleController?.window?.frame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        panel.setFrameOrigin(NSPoint(x: anchor.midX - size.width / 2,
                                     y: anchor.midY - size.height / 2))
        panel.orderFrontRegardless()

        // The panel is non-activating, so it alone never bounces the Dock
        // icon; ask for attention explicitly the way a modal prompt would.
        // No-op while Phi is already the active app.
        handoffPromptAttentionRequest = NSApp.requestUserAttention(.criticalRequest)

        handoffPromptPanel = panel
        handoffPromptSpaceId = spaceId
    }

    /// Closes the handoff prompt. With a `spaceId`, only when the prompt
    /// belongs to that Space — the automatic dismissals (hand-back, takeover,
    /// completion, deletion) must not tear down a newer task's prompt.
    private func dismissHandoffPrompt(forSpaceId spaceId: String? = nil) {
        if let spaceId, handoffPromptSpaceId != spaceId { return }
        if let request = handoffPromptAttentionRequest {
            NSApp.cancelUserAttentionRequest(request)
            handoffPromptAttentionRequest = nil
        }
        handoffPromptPanel?.close()
        handoffPromptPanel = nil
        handoffPromptSpaceId = nil
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
            appendTranscript(taskId: taskId, kind: .status,
                             text: "You handed control back to the agent",
                             detail: terminalNudgeHint(for: t))
            refreshOperatingMask(forSpaceId: spaceId,
                                 activeTabId: currentActiveTabId(forSpaceId: spaceId))
            ChromiumLauncher.sharedInstance().bridge?
                .setAgentMode(true, windowId: Int64(windowId))
            broadcastOwnership(taskId: taskId, owner: "agent")
            // The clock was paused while the user held control; restart it with
            // the between-rounds grace — the driving session may take a while
            // to notice the hand-back and run its next round.
            touchKeepAlive(taskId: taskId, ttlSeconds: Self.interRoundKeepAliveTTL)
            // The agent no longer needs the user — retire a lingering prompt.
            dismissHandoffPrompt(forSpaceId: spaceId)
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
                self.appendTranscript(taskId: taskId, kind: .status,
                                      text: "You handed control back to the agent")
                self.refreshOperatingMask(forSpaceId: spaceId,
                                          activeTabId: self.currentActiveTabId(forSpaceId: spaceId))
                ChromiumLauncher.sharedInstance().bridge?
                    .setAgentMode(true, windowId: Int64(windowId))
                self.broadcastOwnership(taskId: taskId, owner: "agent")
                self.dismissHandoffPrompt(forSpaceId: spaceId)
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
        appendTranscript(taskId: taskId, kind: .status, text: "Agent resumed control")
        refreshOperatingMask(forSpaceId: spaceId,
                             activeTabId: currentActiveTabId(forSpaceId: spaceId))
        ChromiumLauncher.sharedInstance().bridge?
            .setAgentMode(true, windowId: Int64(task.windowId))
        broadcastOwnership(taskId: taskId, owner: "agent")
        // Restart the paused keep-alive clock now that the agent drives again —
        // explicit TTL, since a plain touch only extends and could not shorten
        // a longer window banked before the user took control.
        touchKeepAlive(taskId: taskId, ttlSeconds: Self.defaultKeepAliveTTL)
        dismissHandoffPrompt(forSpaceId: spaceId)
        return true
    }

    // MARK: - Agent autoview

    /// View ▸ Agent Autoview. While enabled, the focused window follows the
    /// operating agent: when a task is running and the user is not already on
    /// a running agent Space, surface it (watch mode). With several agents
    /// running the watched one is never preempted — the next switch happens
    /// when it stops operating (idle between rounds, completion, deletion),
    /// picking the lowest-numbered running task for a stable order. A Space
    /// the user holds control of (handoff in progress) blocks switching away:
    /// they are mid-step there.
    ///
    /// Re-evaluated on every run-state edge, task completion/deletion, and
    /// when the menu toggle turns on. `delay` defers the check past a
    /// deletion's retreat animation so the two switches don't race.
    func autoViewReevaluate(delay: TimeInterval = 0) {
        guard PhiPreferences.AgentSpaces.autoViewEnabled else { return }
        guard delay == 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.autoViewReevaluate()
            }
            return
        }
        let currentSpaceId = SpaceManager.shared.activeSpaceId
        if let currentSpaceId, let current = tasksBySpaceId[currentSpaceId] {
            // Watching a running agent, or holding control of one — stay put.
            if current.status == .running || current.ownership == .user { return }
        }
        guard let next = tasksBySpaceId.values
            .filter({ $0.status == .running && $0.ownership == .agent && $0.windowId != 0 })
            .min(by: { $0.number < $1.number }),
            next.spaceId != currentSpaceId else { return }
        AppLogInfo("[AgentSpace] autoview: surfacing running task \(next.taskId)")
        SpaceManager.shared.activateInFocusedWindow(spaceId: next.spaceId)
    }

    // MARK: - Transcript / user console

    /// Appends one line to the task's live transcript (the console mirror of
    /// the driving code agent's session). Drops silently for unknown tasks —
    /// a late line from a dying round must not resurrect state. `timestamp`
    /// defaults to now; a mirrored session line passes the source event's real
    /// time so backfilled prose sorts into its true place.
    func appendTranscript(taskId: String, kind: AgentTranscriptEntry.Kind,
                          text: String, detail: String? = nil,
                          agent: String? = nil,
                          piToolCallId: String? = nil,
                          piToolState: PiTranscriptToolState? = nil,
                          timestamp: Date = Date()) {
        guard let spaceId = spaceIdByTaskId[taskId],
              let task = tasksBySpaceId[spaceId] else { return }
        AgentTranscriptStore.shared.append(
            taskId: taskId, kind: kind, text: text, detail: detail, agent: agent,
            piToolCallId: piToolCallId, piToolState: piToolState,
            taskNumber: task.number, timestamp: timestamp)
    }

    /// A command the user typed into the agent console: echo it into the
    /// transcript, queue it for the driver's next drain, and broadcast so a
    /// round that is live RIGHT NOW (`waitForUserMessage`) wakes without
    /// polling. The queue stays authoritative — the broadcast is advisory.
    func sendUserMessage(taskId: String, text: String) {
        guard let spaceId = spaceIdByTaskId[taskId],
              let task = tasksBySpaceId[spaceId] else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let capped = String(trimmed.prefix(Self.maxUserMessageChars))
        let message = PendingUserMessage(id: UUID(), text: capped, ts: Date())
        var queue = pendingUserMessagesByTaskId[taskId] ?? []
        queue.append(message)
        if queue.count > Self.maxPendingUserMessages {
            queue.removeFirst(queue.count - Self.maxPendingUserMessages)
        }
        pendingUserMessagesByTaskId[taskId] = queue
        // An idle session has no live round draining the queue, and nothing
        // is ever typed into the agent's terminal — the command sits queued
        // until its next round, so tell the user how to wake it themselves.
        appendTranscript(taskId: taskId, kind: .user, text: capped,
                         detail: task.status == .idle ? terminalNudgeHint(for: task) : nil)
        // Same rule as broadcastOwnership: user text is freeform — serialize,
        // never interpolate into JSON.
        guard let data = try? JSONSerialization.data(withJSONObject: [
                "taskId": taskId, "id": message.id.uuidString, "text": capped]),
              let payload = String(data: data, encoding: .utf8) else { return }
        ExtensionMessaging.shared.broadcastToTaskDriver(
            type: "agentSpace.userMessage",
            payload: payload,
            origin: task.origin,
            driverPrincipalId: task.driverPrincipalId)
    }

    /// The between-rounds delivery warning, scoped to Codex: nothing is ever
    /// typed into its terminal, so queued console input and hand-backs are
    /// only noticed at the session's next turn — the user has to nudge it
    /// themselves. Nil for every other driver: phi-agent's backend resumes
    /// the agent itself, OpenClaw uses its gateway CLI, Pi uses its installed
    /// in-process extension, and Hermes typically waits in waitForUserMessage.
    private func terminalNudgeHint(for task: AgentTask) -> String? {
        guard task.origin == .cdp,
              AgentDriverBadge.make(agentName: task.agentName,
                                    origin: task.origin).label == "Codex"
        else { return nil }
        return "Codex only sees this at its next turn — go to its terminal and type \"continue\" to wake it now."
    }

    /// Hands the queued user commands to the driver and empties the queue.
    func drainUserMessages(taskId: String) -> [PendingUserMessage] {
        let messages = pendingUserMessagesByTaskId[taskId] ?? []
        pendingUserMessagesByTaskId[taskId] = nil
        return messages
    }

    /// Undrained command count, surfaced in `agentSpace.list` rows so the
    /// skill's passive reads (`spaceStatus`) see pending input for free.
    func pendingUserMessageCount(taskId: String) -> Int {
        pendingUserMessagesByTaskId[taskId]?.count ?? 0
    }

    /// How recently a task's console must have been appended to for a
    /// re-created task (same taskId) to CONTINUE the feed instead of starting
    /// fresh. Covers a keep-alive reap between a driver's slow rounds; a
    /// persistent Space re-bound after a real absence still starts clean.
    static let transcriptContinuityWindow: TimeInterval = 30 * 60

    /// Console setup at task (re)start: a reused persistent Space must not
    /// tail last week's transcript — but a task re-created moments after a
    /// keep-alive reap (a driver whose harness kills rounds, Pi's 10s bash
    /// timeout) must not lose the history the user is reading, so only a
    /// stale buffer is cleared. Recency is judged by APPEND time — mirrored
    /// lines carry backdated authored timestamps. The console is never opened
    /// here — the user opens it from the pip's context menu.
    private func beginTranscript(taskId: String, spaceName: String) {
        let continuing = AgentTranscriptStore.shared.lastAppend(taskId: taskId)
            .map { Date().timeIntervalSince($0) < Self.transcriptContinuityWindow }
            ?? false
        if !continuing {
            AgentTranscriptStore.shared.clear(taskId: taskId)
        }
        appendTranscript(taskId: taskId, kind: .status,
                         text: "Task started — Space \(spaceName)")
        // Panel already open: keep its feed pointed at something real if
        // its filter was left on a task that has since ended.
        AgentTranscriptPanelController.shared.refocusIfStale(onto: taskId)
    }

    /// Buffer/queue teardown when a task record goes away. Retention: an OPEN
    /// console keeps the transcript so the user can read how the task ended
    /// (reaped when the panel closes); otherwise it is freed immediately.
    private func tearDownTranscript(taskId: String) {
        pendingUserMessagesByTaskId[taskId] = nil
        if !AgentTranscriptPanelController.shared.isVisible {
            AgentTranscriptStore.shared.clear(taskId: taskId)
        }
    }

    // MARK: - State / completion (inbound from the agent)

    func setStatusCaption(taskId: String, caption: String) {
        guard let spaceId = spaceIdByTaskId[taskId], var task = tasksBySpaceId[spaceId] else { return }
        // The caption doubles as the console's narration stream; only a real
        // change becomes a line (drivers re-assert captions freely).
        if !caption.isEmpty, caption != task.statusCaption {
            appendTranscript(taskId: taskId, kind: .narration, text: caption)
        }
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
            // Console round separators, on real edges only — drivers re-assert
            // their run state freely (round start after a fresh spawn, control
            // guards), and a re-assertion is not a new round.
            let wasRunning = task.status == .running
            if wasRunning != running {
                appendTranscript(taskId: taskId, kind: .round,
                                 text: running ? "round started" : "round ended")
            }
            task.status = running ? .running : .idle
            if running && task.origin == .cdp && !task.persistent {
                // A round is starting to drive: reset the deadline to the short
                // driving window. Plain heartbeats only ever extend the deadline
                // (`touchKeepAlive` maxes), so without this the between-rounds
                // grace bought by a previous round's end would keep masking a
                // driver that dies mid-round for up to 30 minutes. Persistent
                // tasks never expire — their deadline stays .distantFuture.
                task.keepAliveDeadline = Date().addingTimeInterval(Self.defaultKeepAliveTTL)
            }
            tasksBySpaceId[spaceId] = task
            // Both edges matter to autoview: running → surface it; idle → the
            // watched agent finished its step, another running one may take over.
            autoViewReevaluate()
        }
    }

    /// `tabId` is accepted for protocol compatibility (0 = the displayed
    /// tab) but unused: the overlay is mounted per content view, which
    /// already scopes the cursor to what is on screen.
    func setCursor(taskId: String, tabId: Int, point: CGPoint) {
        guard let spaceId = spaceIdByTaskId[taskId], tasksBySpaceId[spaceId] != nil else { return }
        cursorBySpaceId[spaceId] = point
        cursorMoved.send(AgentCursorUpdate(spaceId: spaceId, point: point))
    }

    func showEffect(taskId: String, kind: AgentEffect.Kind,
                    point: CGPoint?, size: CGSize?, dy: CGFloat?) {
        guard let spaceId = spaceIdByTaskId[taskId], tasksBySpaceId[spaceId] != nil else { return }
        effectRequested.send(
            AgentEffect(spaceId: spaceId, kind: kind, point: point, size: size, dy: dy))
    }

    func markError(taskId: String, message: String) {
        guard let spaceId = spaceIdByTaskId[taskId], var task = tasksBySpaceId[spaceId] else { return }
        appendTranscript(taskId: taskId, kind: .error, text: message)
        task.status = .failed(message: message)
        task.hasUnseenError = true
        tasksBySpaceId[spaceId] = task
    }

    /// Task finished. EPHEMERAL agent Spaces exist only while their task is
    /// running, so completion flips agent mode off, drops the task record,
    /// and deletes the Space (closing its window); the `keep` flag is
    /// accepted for protocol compatibility but never leaves an ephemeral
    /// Space lingering. A PERSISTENT task's Space is a permanent workspace:
    /// completion ends only the TASK — its window closes, the Space row (and
    /// its tagged rows) stays in the switcher, and a later task with the same
    /// taskId re-binds to it.
    func taskDidComplete(taskId: String, success: Bool, keep: Bool, message: String? = nil) {
        guard let spaceId = spaceIdByTaskId[taskId], let task = tasksBySpaceId[spaceId] else { return }
        // The task record is removed either way; keep the driver-reported
        // outcome observable in the log (there is no surviving UI to show it
        // on).
        AppLogInfo("[AgentSpace] task \(taskId) completed success=\(success)"
            + " persistent=\(task.persistent)"
            + (message.map { " message=\($0)" } ?? ""))
        PostHogSDK.shared.capture("agent_task_completed", properties: [
            "origin": task.origin == .cdp ? "cdp" : "phi_agent",
            "persistent": task.persistent,
            "agent_name": AgentDriverBadge.telemetryName(task.agentName),
            "success": success,
        ])
        if let masked = task.maskedTabId {
            AgentAnimationManager.shared.setActive(false, for: masked)
        }
        AgentPageTheme.shared.clear(windowId: task.windowId)
        ChromiumLauncher.sharedInstance().bridge?
            .setAgentMode(false, windowId: Int64(task.windowId))
        appendTranscript(taskId: taskId, kind: success ? .status : .error,
                         text: success ? "Task completed" : "Task failed",
                         detail: message)
        tasksBySpaceId[spaceId] = nil
        cursorBySpaceId[spaceId] = nil
        spaceIdByTaskId[taskId] = nil
        tearDownTranscript(taskId: taskId)
        dismissHandoffPrompt(forSpaceId: spaceId)
        if task.persistent {
            SpaceManager.shared.closeSpaceWindows(spaceId: spaceId)
        } else {
            SpaceManager.shared.deleteSpace(spaceId: spaceId)
        }
        stopKeepAliveSweepIfIdle()
        // The watched agent may just have finished — hand the view to the next
        // running one, after the deletion retreat's animation settles.
        autoViewReevaluate(delay: 0.8)
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
        AgentPageTheme.shared.clear(windowId: task.windowId)
        appendTranscript(taskId: task.taskId, kind: .status,
                         text: "Space deleted by the user — task ended")
        tasksBySpaceId[spaceId] = nil
        cursorBySpaceId[spaceId] = nil
        spaceIdByTaskId[task.taskId] = nil
        tearDownTranscript(taskId: task.taskId)
        dismissHandoffPrompt(forSpaceId: spaceId)
        stopKeepAliveSweepIfIdle()
        autoViewReevaluate(delay: 0.8)
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
        refreshOperatingPageTheme(for: task)
    }

    /// Layer 2 of the mask — the in-page recoloring — follows the same signal as
    /// the native wash so the two can never disagree about who owns the page.
    /// Scoped to the window rather than the masked tab: CDP addresses targets by
    /// window, and every page in an agent window belongs to the agent anyway.
    private func refreshOperatingPageTheme(for task: AgentTask) {
        guard task.windowId != 0 else { return }
        guard task.maskedTabId != nil else {
            AgentPageTheme.shared.clear(windowId: task.windowId)
            return
        }
        guard let themeContext = MainBrowserWindowControllersManager.shared
                .getBrowserState(for: task.windowId)?.themeContext else { return }
        let appearance = themeContext.currentAppearance
        let color = themeContext.currentTheme.color(
            for: .themeColor, appearance: appearance)
        AgentPageTheme.shared.apply(
            windowId: task.windowId, themeColor: color, appearance: appearance)
    }

    /// Re-issues the in-page recolor for every task currently wearing the
    /// mask. The injected sheet carries a different palette per appearance, so
    /// a theme or appearance flip must restyle live targets; the native wash
    /// (layer 1) refreshes through each window's own theme pipeline.
    private func refreshMaskedPageThemes() {
        for task in tasksBySpaceId.values where task.maskedTabId != nil {
            refreshOperatingPageTheme(for: task)
        }
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
        // Delivery needs the task's owning principal; once the record is gone
        // the event is deliberately dropped — drivers learn of an ended task
        // from its disappearance in agentSpace.list, not from a final
        // ownership flip.
        guard let task = task(forTaskId: taskId) else { return }
        ExtensionMessaging.shared.broadcastToTaskDriver(
            type: "agentSpace.ownershipChanged",
            payload: payload,
            origin: task.origin,
            driverPrincipalId: task.driverPrincipalId)
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

    /// True for any agent Space — ephemeral or persistent — matched by its
    /// visual signature. The display-order grouping (agent Spaces after user
    /// Spaces, with a divider between the groups) keys off this, so both kinds
    /// land on the agent side of the divider.
    var isAnyAgentSpace: Bool {
        isAgentSpace || AgentSpaceManager.isPersistentAgentSpaceModel(
            iconName: iconName, colorHex: colorHex)
    }
}

// MARK: - Handoff prompt panel

/// Borderless floating panel for the handoff prompt. `canBecomeKey` so its
/// buttons and keyboard shortcuts work despite the borderless style mask.
private final class HandoffPromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Content of the handoff prompt: the agent's message and the two choices,
/// styled like a system alert but hosted in the floating panel above.
private struct HandoffPromptView: View {
    let title: String
    let message: String
    let switchTitle: String
    let laterTitle: String
    let onSwitch: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                Button(action: onSwitch) {
                    Text(switchTitle).frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                Button(action: onLater) {
                    Text(laterTitle).frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        }
    }
}
