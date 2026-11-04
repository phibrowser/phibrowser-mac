// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

/// Window-scoped state for the screen-share quick switch: while a tab share
/// is running, hovering another tab in this window offers to share that tab
/// instead, without restarting the share. Owned by `BrowserState` (one
/// instance per window).
///
/// Only the most recently started share is addressed; the framework decides
/// which session that is and whether a tab may join it, and re-checks when
/// the switch is requested.
final class BrowserTabSharingState: ObservableObject {
    @Published private(set) var snapshot: TabSharingSnapshot = .empty
    /// The session a tab row can switch to itself; nil while a switch is in
    /// flight or when the share cannot switch tabs.
    @Published private(set) var replaceableSession: TabSharingSnapshot.Session?

    private let windowId: Int
    private let client: TabSharingClient
    private var pendingSwitchTargetTabId: Int?

    init(windowId: Int, client: TabSharingClient = .live) {
        self.windowId = windowId
        self.client = client
    }

    /// A window opened mid-share receives no push until the share changes.
    func start() {
        if let current = client.snapshot(windowId) {
            apply(current)
        }
    }

    func apply(_ newSnapshot: TabSharingSnapshot) {
        guard newSnapshot.revision >= snapshot.revision else { return }
        if newSnapshot != snapshot {
            AppLogDebug("[TabSharing] windowId=\(windowId) snapshot revision=\(newSnapshot.revision) " +
                        "session=\(newSnapshot.selectedSession?.sessionId ?? "none")")
        }
        snapshot = newSnapshot
        refreshReplaceableSession()
    }

    func canShareInstead(tabId: Int) -> Bool {
        guard let session = replaceableSession,
              tabId != session.capturerTabId,
              tabId != session.sharedTabId else {
            return false
        }
        return client.availability(session.sessionId, windowId, tabId).isSuccess
    }

    func shareInstead(tabId: Int) {
        guard canShareInstead(tabId: tabId), let session = replaceableSession else { return }
        pendingSwitchTargetTabId = tabId
        refreshReplaceableSession()
        AppLogInfo("[TabSharing] switch requested windowId=\(windowId) " +
                   "capturerTabId=\(session.capturerTabId) targetTabId=\(tabId)")

        client.switchSharedTab(session.sessionId, windowId, tabId) { [weak self] result in
            guard let self else { return }
            self.pendingSwitchTargetTabId = nil
            if !result.isSuccess {
                AppLogWarn("[TabSharing] switch finished status=\(result.status.rawValue) " +
                           "reason=\(result.reason ?? "none") targetTabId=\(tabId)")
            }
            if let latest = self.client.snapshot(self.windowId) {
                self.apply(latest)
            } else {
                self.refreshReplaceableSession()
            }
        }
    }

    private func refreshReplaceableSession() {
        let session = snapshot.selectedSession.flatMap { session in
            pendingSwitchTargetTabId == nil
                && session.surfaceType == .tab
                && session.canSwitch
                && !session.isSwitching ? session : nil
        }
        if session != replaceableSession {
            replaceableSession = session
        }
    }
}
