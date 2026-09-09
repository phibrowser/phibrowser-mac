// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine

/// The operating mask for tabs in the user's OWN Spaces.
///
/// Agent Spaces derive their mask from state the app already owns: attach
/// activates the target, so the operating tab is always the hidden window's
/// active tab (`AgentSpaceManager.refreshOperatingMask`). A user Space cannot
/// reuse that — attach there is deliberately passive, so the driven tab is
/// usually a background tab while the user works in another one — and page
/// automation never passes through Swift at all: `AgentCDPListener` hands the
/// connection's file descriptor to Chromium, which owns every frame after
/// that.
///
/// So the browser reports instead. Chromium raises
/// `agentDidOperateUserSpaceTab` for the first drive command a CDP session
/// aims at a user-Space tab and re-arms at most once a second after that; this
/// registry turns that stream into mask state, and pushes the user's takeovers
/// back down so the browser can refuse the driver outright. Nothing here
/// depends on a driver reporting anything about itself — which is exactly how
/// the previous, extension-driven mask was lost.
@MainActor
final class AgentUserSpaceDriveRegistry {
    static let shared = AgentUserSpaceDriveRegistry()

    /// One driving session's hold on one tab. A hold outlives the user taking
    /// the tab back: the driver is refused meanwhile, but the record is what
    /// keeps the pill — and its "Hand back" — on screen, and what says who to
    /// hand it back TO.
    struct Record {
        let sessionId: Int64
        var tabId: Int
        var windowId: Int
        var lastSeen: Date
        /// The user holds this tab; the browser is refusing this driver.
        var reclaimed: Bool = false
        /// Who to name on the pill. Known exactly for holds the app armed
        /// itself (it authenticated the caller); empty for browser-reported
        /// drives, which fall back to the roster's best guess.
        var driverName: String = ""
    }

    /// An `agentSpace.spaces.openTab` the app has issued but Chromium has not
    /// created yet. Opening a tab in the user's Space is the one drive the
    /// browser never sees — the app performs it itself, so no CDP command is
    /// ever sent and nothing would be reported.
    private struct PendingOpen {
        let windowId: Int
        let principalId: String
        let driverName: String
        let at: Date
    }

    /// A driver that stops sending commands but stays attached leaves no close
    /// event behind. Sized against how an agent actually paces itself: reads
    /// re-arm as well as drives, but a model's turnaround between rounds still
    /// leaves gaps of tens of seconds, and a mask that blinks off inside a
    /// running task is worse than one that lingers a moment past it. Settable
    /// so tests can drive the expiry paths without waiting them out.
    var idleTimeout: TimeInterval = 30
    /// How long a takeover keeps refusing drivers on that tab. Deliberately
    /// much longer than a driver's session: if the record died with the
    /// session, the agent's next run would silently re-mask the tab the user
    /// just took back.
    var reclaimGrace: TimeInterval = 30 * 60
    private static let sweepInterval: TimeInterval = 2

    private var recordsBySessionId: [Int64: Record] = [:]
    private var reclaimedTabs: [Int: Date] = [:]
    private var sweepTimer: Timer?
    private var pendingOpens: [PendingOpen] = []
    /// Synthetic session keys for app-armed holds, one per driver, allocated
    /// downwards so they can never collide with the browser's (which count up
    /// from 1). One per driver is what makes a second open MOVE that agent's
    /// mask instead of masking two tabs at once.
    private var appSessionIdByPrincipal: [String: Int64] = [:]
    private var nextAppSessionId: Int64 = -1
    /// A tab has to appear within this long of the open, or the expectation is
    /// dropped — the alternative is masking whatever tab the user opens next.
    private static let openExpectationTTL: TimeInterval = 10

    /// Emits a tabId whenever its drive state changes (armed, moved, cleared) —
    /// the pill mounts off this. The mask itself rides
    /// `AgentAnimationManager.stateChanged`, which fires from the same paths.
    let driveStateChanged = PassthroughSubject<Int, Never>()

    private init() {}

#if DEBUG
    /// Tests share the singleton; clear every hold, takeover, and mask between
    /// cases so one test's state can't decide the next one's verdict.
    func resetForTesting() {
        for record in recordsBySessionId.values {
            AgentAnimationManager.shared.setActive(false, for: record.tabId)
        }
        recordsBySessionId.removeAll()
        reclaimedTabs.removeAll()
        pendingOpens.removeAll()
        appSessionIdByPrincipal.removeAll()
        sweepTimer?.invalidate()
        sweepTimer = nil
        idleTimeout = 30
        reclaimGrace = 30 * 60
    }
#endif

    // MARK: - Browser reports

    /// A CDP session drove `tabId`. First report for the session arms the mask;
    /// later ones re-arm the idle timer. A session naming a different tab has
    /// MOVED, so its previous tab is unmasked — one driver, one masked tab.
    func didOperate(tabId: Int, windowId: Int, sessionId: Int64) {
        // A tab the user has taken back stays theirs. The browser refuses the
        // driver's commands, so this is belt-and-braces: it also keeps a
        // refusal from re-arming the mask through the report path.
        if isReclaimed(tabId: tabId) { return }

        if var existing = recordsBySessionId[sessionId] {
            let previousTab = existing.tabId
            existing.tabId = tabId
            existing.windowId = windowId
            existing.lastSeen = Date()
            existing.reclaimed = false
            recordsBySessionId[sessionId] = existing
            if previousTab != tabId {
                clearMaskIfUndriven(tabId: previousTab)
            }
        } else {
            recordsBySessionId[sessionId] = Record(
                sessionId: sessionId, tabId: tabId, windowId: windowId,
                lastSeen: Date())
            AppLogInfo("[AgentUserSpace] agent drives tab \(tabId) "
                       + "(window \(windowId), session \(sessionId))")
        }
        // Unconditional and idempotent: this is also how the mask comes back
        // after a hand back, where the record already exists on the same tab.
        applyMask(tabId: tabId)
        startSweepIfNeeded()
    }

    /// The app is about to open a tab in one of the user's Spaces on an
    /// agent's behalf. Chromium creates the tab internally, so this open is
    /// invisible to the drive reports — the expectation recorded here is
    /// claimed by the matching `newTabCreated`.
    func agentWillOpenTab(inWindow windowId: Int, principalId: String?, driverName: String) {
        pendingOpens.append(PendingOpen(
            windowId: windowId,
            principalId: principalId ?? "anonymous",
            driverName: driverName,
            at: Date()))
    }

    /// A tab was created. Claims the oldest expectation for its window, if any
    /// — every other tab creation (the user's own, most of them) falls through
    /// untouched.
    func noteTabCreated(tabId: Int, windowId: Int) {
        let now = Date()
        pendingOpens.removeAll { now.timeIntervalSince($0.at) > Self.openExpectationTTL }
        guard let index = pendingOpens.firstIndex(where: { $0.windowId == windowId })
        else { return }
        let pending = pendingOpens.remove(at: index)
        guard !isReclaimed(tabId: tabId) else { return }

        let sessionId = appSessionId(forPrincipal: pending.principalId)
        if let existing = recordsBySessionId[sessionId], existing.tabId != tabId {
            // Same agent, another tab: move its mask rather than add a second.
            recordsBySessionId[sessionId] = nil
            clearMaskIfUndriven(tabId: existing.tabId)
        }
        recordsBySessionId[sessionId] = Record(
            sessionId: sessionId, tabId: tabId, windowId: windowId,
            lastSeen: now, driverName: pending.driverName)
        AppLogInfo("[AgentUserSpace] agent opened tab \(tabId) in the user's Space "
                   + "(window \(windowId), driver \(pending.driverName))")
        applyMask(tabId: tabId)
        startSweepIfNeeded()
    }

    private func appSessionId(forPrincipal principalId: String) -> Int64 {
        if let existing = appSessionIdByPrincipal[principalId] { return existing }
        let allocated = nextAppSessionId
        nextAppSessionId -= 1
        appSessionIdByPrincipal[principalId] = allocated
        return allocated
    }

    /// The session is working on `tabId` without driving it. Deliberately
    /// cannot arm: an agent that opens a page and reads it has not claimed it,
    /// and a mask over a tab nobody is driving blocks the user's own input for
    /// nothing. It only refreshes a hold that already exists — which is what
    /// keeps the mask up across an agent's thinking time.
    func didObserve(tabId: Int, windowId: Int, sessionId _: Int64) {
        guard !isReclaimed(tabId: tabId) else { return }
        let now = Date()
        // Every live hold on the tab is refreshed, not just the reporting
        // session's: the hold that matters here is usually the app's own (the
        // tab it opened for this agent), filed under a different key.
        for id in sessionIds(forTabId: tabId)
        where recordsBySessionId[id]?.reclaimed == false {
            recordsBySessionId[id]?.lastSeen = now
            recordsBySessionId[id]?.windowId = windowId
        }
    }

    /// The driving session ended — a real close, not a guess.
    func didStop(tabId: Int, sessionId: Int64) {
        guard let record = recordsBySessionId.removeValue(forKey: sessionId) else { return }
        AppLogInfo("[AgentUserSpace] driver released tab \(record.tabId) "
                   + "(session \(sessionId))")
        clearMaskIfUndriven(tabId: record.tabId)
        stopSweepIfIdle()
    }

    /// The tab went away; drop every driver's hold on it. Also clears the
    /// takeover record — a new tab could reuse the id.
    func tabWasRemoved(tabId: Int) {
        for sessionId in sessionIds(forTabId: tabId) {
            recordsBySessionId[sessionId] = nil
        }
        reclaimedTabs[tabId] = nil
        pushReclaimedTabs()
        clearMaskIfUndriven(tabId: tabId)
        stopSweepIfIdle()
    }

    // MARK: - Queries

    /// Any hold on `tabId` — driving, or reclaimed and waiting to be handed
    /// back. This is what decides whether the control pill is mounted.
    func record(forTabId tabId: Int) -> Record? {
        recordsBySessionId.values.first { $0.tabId == tabId && !$0.reclaimed }
            ?? recordsBySessionId.values.first { $0.tabId == tabId }
    }

    /// An agent is driving this tab right now — the mask's condition. A tab the
    /// user has taken back is NOT driven, even though its hold survives.
    func isDriven(tabId: Int) -> Bool {
        recordsBySessionId.values.contains { $0.tabId == tabId && !$0.reclaimed }
    }

    /// The user holds this tab and a driver is still attached to hand it back
    /// to — the pill shows "Hand back" and "Finish".
    func isReclaimedWithDriver(tabId: Int) -> Bool {
        recordsBySessionId.values.contains { $0.tabId == tabId && $0.reclaimed }
    }

    // MARK: - Takeover

    /// The user pressed "Take control" on a driven tab of their own. Drops the
    /// mask and tells the browser to refuse that tab's drive commands: the
    /// refusal is the browser's, so the driver cannot decline to honor it.
    func takeControl(tabId: Int) {
        AppLogInfo("[AgentUserSpace] user took control of tab \(tabId)")
        reclaimedTabs[tabId] = Date()
        pushReclaimedTabs()
        // The holds stay, flagged: the driver is refused browser-side, and the
        // pill keeps its "Hand back" so an interrupted run can be resumed —
        // the login-or-captcha case this whole affordance exists for.
        for sessionId in sessionIds(forTabId: tabId) {
            recordsBySessionId[sessionId]?.reclaimed = true
        }
        clearMaskIfUndriven(tabId: tabId)
        startSweepIfNeeded()  // the grace still has to lapse on a clock
        stopSweepIfIdle()
    }

    /// The user gives the tab back. Clearing the reclaim is what actually
    /// unblocks the driver — the browser stops refusing its commands, and the
    /// report that follows re-arms the mask on its own. The mask goes back up
    /// now rather than on that report so the handoff is visible immediately;
    /// if the agent never resumes, the idle sweep lifts it within `idleTimeout`.
    func handBack(tabId: Int) {
        guard isReclaimedWithDriver(tabId: tabId) else { return }
        AppLogInfo("[AgentUserSpace] user handed tab \(tabId) back to the agent")
        reclaimedTabs[tabId] = nil
        pushReclaimedTabs()
        for sessionId in sessionIds(forTabId: tabId) {
            recordsBySessionId[sessionId]?.reclaimed = false
            recordsBySessionId[sessionId]?.lastSeen = Date()
        }
        applyMask(tabId: tabId)
        startSweepIfNeeded()
    }

    /// The user is done with this episode: the pill goes away and the hold is
    /// dropped. It does NOT block the agent — taking control is the only thing
    /// that does. So the reclaim is lifted here too: if the agent drives this
    /// tab again, its report arms a fresh mask and the pill comes back, the
    /// same as if the user had never been involved.
    func finish(tabId: Int) {
        AppLogInfo("[AgentUserSpace] user finished with the agent on tab \(tabId)")
        reclaimedTabs[tabId] = nil
        pushReclaimedTabs()
        for sessionId in sessionIds(forTabId: tabId) {
            recordsBySessionId[sessionId] = nil
        }
        clearMaskIfUndriven(tabId: tabId)
        stopSweepIfIdle()
        driveStateChanged.send(tabId)
    }

    func isReclaimed(tabId: Int) -> Bool {
        guard let since = reclaimedTabs[tabId] else { return false }
        return Date().timeIntervalSince(since) < reclaimGrace
    }

    // MARK: - Mask plumbing

    private func sessionIds(forTabId tabId: Int) -> [Int64] {
        recordsBySessionId.filter { $0.value.tabId == tabId }.map(\.key)
    }

    /// Idempotent: every report re-applies, and only a real change is
    /// published — a driver typing a form must not republish once a second.
    private func applyMask(tabId: Int) {
        guard !AgentAnimationManager.shared.isActive(for: tabId) else { return }
        AgentAnimationManager.shared.setActive(true, for: tabId)
        driveStateChanged.send(tabId)
    }

    /// Lifts the mask only once no driver still holds the tab (two agents can
    /// name the same tab; the last one to leave clears it).
    private func clearMaskIfUndriven(tabId: Int) {
        guard !isDriven(tabId: tabId) else { return }
        AgentAnimationManager.shared.setActive(false, for: tabId)
        driveStateChanged.send(tabId)
    }

    private func pushReclaimedTabs() {
        let live = reclaimedTabs
            .filter { Date().timeIntervalSince($0.value) < reclaimGrace }
            .keys
            .map { NSNumber(value: Int64($0)) }
        ChromiumLauncher.sharedInstance().bridge?.setUserReclaimedTabs(live)
    }

    // MARK: - Idle sweep

    private func startSweepIfNeeded() {
        guard sweepTimer == nil, isAnyoneDriving || !reclaimedTabs.isEmpty else { return }
        sweepTimer = Timer.scheduledTimer(
            withTimeInterval: Self.sweepInterval, repeats: true
        ) { _ in
            MainActor.assumeIsolated { AgentUserSpaceDriveRegistry.shared.sweep() }
        }
    }

    private var isAnyoneDriving: Bool {
        recordsBySessionId.values.contains { !$0.reclaimed }
    }

    private func stopSweepIfIdle() {
        guard !isAnyoneDriving, reclaimedTabs.isEmpty else { return }
        sweepTimer?.invalidate()
        sweepTimer = nil
    }

    /// Covers the one case a close event can't: a client that stays attached
    /// but stops driving. Expired takeovers lapse on the same tick.
    func sweep() {
        let now = Date()
        // A reclaimed hold is deliberately exempt: no reports arrive while the
        // browser refuses that driver, so an idle rule would retire the pill —
        // and its "Hand back" — seconds after the user took the tab.
        for (sessionId, record) in recordsBySessionId
        where !record.reclaimed && now.timeIntervalSince(record.lastSeen) > idleTimeout {
            recordsBySessionId[sessionId] = nil
            AppLogDebug("[AgentUserSpace] driver idle on tab \(record.tabId); mask cleared")
            clearMaskIfUndriven(tabId: record.tabId)
        }
        let expired = reclaimedTabs.filter {
            now.timeIntervalSince($0.value) >= reclaimGrace
        }
        if !expired.isEmpty {
            for tabId in expired.keys {
                reclaimedTabs[tabId] = nil
                // The takeover simply ran out: retire its pill rather than
                // leaving a "Hand back" for a decision that already lapsed.
                for sessionId in sessionIds(forTabId: tabId)
                where recordsBySessionId[sessionId]?.reclaimed == true {
                    recordsBySessionId[sessionId] = nil
                }
                driveStateChanged.send(tabId)
            }
            pushReclaimedTabs()
        }
        stopSweepIfIdle()
    }
}

/// Who to name on the pill over a driven user-Space tab.
///
/// Best effort by construction: the app authenticates every CDP peer and then
/// hands the raw file descriptor to Chromium, so once a connection is injected
/// nothing correlates a browser-reported driving session back to the identity
/// that opened it. With one agent connected — the normal case — the answer is
/// unambiguous; with several the pill stays generic ("Code agent") rather than
/// naming the wrong one. Exact attribution needs the driver's principal
/// carried down to the DevTools session, which content does not expose today.
@MainActor
final class AgentCDPDriverRoster {
    static let shared = AgentCDPDriverRoster()

    /// How long an injected connection counts as "recent" for naming.
    private static let window: TimeInterval = 10 * 60

    private var lastSeenByKey: [String: (name: String, at: Date)] = [:]

    private init() {}

    /// A stock-CDP connection from `displayName` was just handed to Chromium.
    func noteInjection(key: String, displayName: String) {
        lastSeenByKey[key] = (displayName, Date())
    }

    /// The single agent that has opened a CDP connection recently, or nil when
    /// none has or several have.
    var soleRecentDriverName: String? {
        let cutoff = Date().addingTimeInterval(-Self.window)
        let recent = lastSeenByKey.values.filter { $0.at > cutoff }
        guard recent.count == 1 else { return nil }
        return recent.first?.name
    }

    /// Whether that single recent driver is the browser's own agent.
    ///
    /// Decided by the identity KEY, never by the display name. `firstPartyKey`
    /// is minted only by `AgentPeerIdentity.firstPartyAgent`, which is the
    /// verified check — Phi-signed peer, running the phi-agent bundle, and
    /// descended from this bundle's `Phi Sentinel.app`. Every other identity
    /// is keyed "teamId:signingId" or "unsigned:<path>", and a team identifier
    /// is a 10-character Apple-issued string, so no outside agent can present
    /// this key. A NAME could be worn by anything — an app or a directory that
    /// calls itself "Phi Agent" — which is exactly why the pill must not
    /// decide who is Phi from one.
    var soleRecentDriverIsFirstParty: Bool {
        let cutoff = Date().addingTimeInterval(-Self.window)
        let recent = lastSeenByKey.filter { $0.value.at > cutoff }
        guard recent.count == 1, let key = recent.first?.key else { return false }
        return key == AgentPeerIdentity.firstPartyKey
    }
}
