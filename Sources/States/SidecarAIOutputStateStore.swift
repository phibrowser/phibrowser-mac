// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum SidecarAIOutputPhase: String, Decodable {
    case idle
    case submitted
    case streaming

    var isActive: Bool {
        self != .idle
    }
}

struct SidecarAIOutputPayload: Decodable {
    let tabId: Int
    let windowId: Int
    let active: Bool
    let phase: SidecarAIOutputPhase
    let seq: Int
}

struct SidecarAIOutputState: Equatable {
    let windowId: Int
    let active: Bool
    let phase: SidecarAIOutputPhase
    let seq: Int
    let hasCompletedOutput: Bool
}

struct SidecarAIOutputStateTracker {
    private(set) var statesByTabId: [Int: SidecarAIOutputState] = [:]

    mutating func apply(_ payload: SidecarAIOutputPayload) -> SidecarAIOutputState? {
        guard payload.active == payload.phase.isActive else { return nil }

        let previous = statesByTabId[payload.tabId]
        if let previous, payload.seq <= previous.seq { return nil }

        let didCompleteOutput = previous?.active == true && !payload.active
        let state = SidecarAIOutputState(
            windowId: payload.windowId,
            active: payload.active,
            phase: payload.phase,
            seq: payload.seq,
            hasCompletedOutput: previous?.hasCompletedOutput == true || didCompleteOutput
        )
        statesByTabId[payload.tabId] = state
        return state
    }

    @discardableResult
    mutating func remove(tabId: Int) -> SidecarAIOutputState? {
        statesByTabId.removeValue(forKey: tabId)
    }

    mutating func remove(tabIds: Set<Int>) {
        for tabId in tabIds {
            statesByTabId.removeValue(forKey: tabId)
        }
    }

    mutating func removeAll() {
        statesByTabId.removeAll()
    }
}

@MainActor
final class SidecarAIOutputStateStore {
    static let shared = SidecarAIOutputStateStore()

    nonisolated static let extensionId = "fenmfiepnpdlhplemgijlimpbebebljo"

    private var tracker = SidecarAIOutputStateTracker()

    func handle(_ context: ExtensionMessageContext) {
        guard context.senderId == Self.extensionId else {
            AppLogDebug("[AIOutputState] Dropped message from ccsender=\(context.senderId)")
            return
        }
        guard let data = context.payload.data(using: .utf8),
              let payload = try? JSONDecoder().decode(SidecarAIOutputPayload.self, from: data) else {
            AppLogDebug("[AIOutputState] Dropped invalid payload: \(context.payload)")
            return
        }
        guard let state = tracker.apply(payload) else {
            AppLogDebug(
                "[AIOutputState] Dropped stale or inconsistent state " +
                "tab=\(payload.tabId) phase=\(payload.phase.rawValue) seq=\(payload.seq)"
            )
            return
        }
        guard let resolved = resolveTab(payload.tabId) else {
            AppLogDebug("[AIOutputState] No content tab for id=\(payload.tabId)")
            return
        }

        for tab in affectedTabs(for: resolved.tab, in: resolved.state) {
            tab.hasPairedChat = state.hasCompletedOutput
            tab.isPairedChatGenerating = state.active
        }
    }

    func removeConversation(boundTo tabId: Int) {
        guard let resolved = resolveTab(tabId) else {
            tracker.remove(tabId: tabId)
            return
        }

        let tabs = affectedTabs(for: resolved.tab, in: resolved.state)
        tracker.remove(tabIds: Set(tabs.map(\.guid)))
        for tab in tabs {
            tab.hasPairedChat = false
            tab.isPairedChatGenerating = false
        }
    }

    func removeConversation(boundTo identifier: String, in browserState: BrowserState) {
        guard let tab = browserState.tab(forChatIdentifier: identifier) else { return }
        guard let split = browserState.splitGroup(forTabId: tab.guid) else {
            removeConversation(boundTo: tab.guid)
            return
        }

        let splitTabIds = Set([split.primaryTabId, split.secondaryTabId])
        let liveSplitTabs = browserState.tabs.filter { splitTabIds.contains($0.guid) }
        let representedSplitTabs = representedTabs(
            forLiveTabs: liveSplitTabs,
            in: browserState
        )
        tracker.remove(tabId: tab.guid)

        let survivingChatTab = liveSplitTabs.first { candidate in
            candidate.guid != tab.guid &&
                browserState.aiChatTabs[browserState.getTabIdentifier(for: candidate)] != nil
        }
        if let survivingChatTab,
           let survivingState = tracker.statesByTabId[survivingChatTab.guid] {
            apply(survivingState, to: representedSplitTabs)
            return
        }

        tracker.remove(tabIds: splitTabIds)
        clear(tabs: representedSplitTabs)
    }

    func contentTabDidClose(_ tabId: Int) {
        tracker.remove(tabId: tabId)
    }

    func removeAll() {
        tracker.removeAll()
        for controller in MainBrowserWindowControllersManager.shared.getAllWindows() {
            let state = controller.browserState
            clear(tabs: representedTabs(forLiveTabs: state.tabs, in: state))
        }
    }

    private func resolveTab(_ tabId: Int) -> (tab: Tab, state: BrowserState)? {
        for controller in MainBrowserWindowControllersManager.shared.getAllWindows() {
            let state = controller.browserState
            if let tab = state.resolveTab(tabId) {
                return (tab, state)
            }
        }
        return nil
    }

    private func affectedTabs(for tab: Tab, in browserState: BrowserState) -> [Tab] {
        let liveTabs: [Tab]
        if let split = browserState.splitGroup(forTabId: tab.guid) {
            let splitTabIds = Set([split.primaryTabId, split.secondaryTabId])
            liveTabs = browserState.tabs.filter { splitTabIds.contains($0.guid) }
        } else {
            liveTabs = [tab]
        }
        return representedTabs(forLiveTabs: liveTabs, in: browserState)
    }

    private func representedTabs(forLiveTabs liveTabs: [Tab], in browserState: BrowserState) -> [Tab] {
        let liveTabIds = Set(liveTabs.map(\.guid))
        return liveTabs + browserState.pinnedTabs.filter { liveTabIds.contains($0.guid) }
    }

    private func apply(_ state: SidecarAIOutputState, to tabs: [Tab]) {
        for tab in tabs {
            tab.hasPairedChat = state.hasCompletedOutput
            tab.isPairedChatGenerating = state.active
        }
    }

    private func clear(tabs: [Tab]) {
        for tab in tabs {
            tab.hasPairedChat = false
            tab.isPairedChatGenerating = false
        }
    }
}
