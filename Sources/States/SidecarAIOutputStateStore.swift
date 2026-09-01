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
    let hasStartedGeneration: Bool
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
            hasStartedGeneration: previous?.hasStartedGeneration == true || payload.active,
            hasCompletedOutput: previous?.hasCompletedOutput == true || didCompleteOutput
        )
        statesByTabId[payload.tabId] = state
        return state
    }

    @discardableResult
    mutating func remove(tabId: Int, windowId: Int? = nil) -> SidecarAIOutputState? {
        if let windowId,
           statesByTabId[tabId]?.windowId != windowId {
            return nil
        }
        return statesByTabId.removeValue(forKey: tabId)
    }

    mutating func remove(tabIds: Set<Int>, windowId: Int? = nil) {
        for tabId in tabIds {
            remove(tabId: tabId, windowId: windowId)
        }
    }

    mutating func moveState(
        from sourceTabId: Int,
        to destinationTabId: Int,
        windowId: Int
    ) -> SidecarAIOutputState? {
        guard sourceTabId != destinationTabId else {
            return statesByTabId[destinationTabId].flatMap {
                $0.windowId == windowId ? $0 : nil
            }
        }
        guard let sourceState = remove(tabId: sourceTabId, windowId: windowId) else {
            return statesByTabId[destinationTabId].flatMap {
                $0.windowId == windowId ? $0 : nil
            }
        }
        let movedState = SidecarAIOutputState(
            windowId: windowId,
            active: sourceState.active,
            phase: sourceState.phase,
            seq: sourceState.seq,
            hasStartedGeneration: sourceState.hasStartedGeneration,
            hasCompletedOutput: sourceState.hasCompletedOutput
        )
        statesByTabId[destinationTabId] = movedState
        return movedState
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
        guard let browserState = MainBrowserWindowControllersManager.shared.getBrowserState(
            for: payload.windowId
        ) else {
            AppLogDebug("[AIOutputState] No browser window for id=\(payload.windowId)")
            return
        }
        apply(payload, in: browserState)
    }

    @discardableResult
    func apply(_ payload: SidecarAIOutputPayload, in browserState: BrowserState) -> Bool {
        guard browserState.windowId == payload.windowId,
              let tab = browserState.resolveTab(payload.tabId) else {
            AppLogDebug(
                "[AIOutputState] No content tab for " +
                "window=\(payload.windowId) tab=\(payload.tabId)"
            )
            return false
        }
        guard let state = tracker.apply(payload) else {
            AppLogDebug(
                "[AIOutputState] Dropped stale or inconsistent state " +
                "tab=\(payload.tabId) phase=\(payload.phase.rawValue) seq=\(payload.seq)"
            )
            return false
        }

        apply(state, to: affectedTabs(for: tab, in: browserState))
        return true
    }

    func removeConversation(boundTo tabId: Int, windowId: Int) {
        guard let browserState = MainBrowserWindowControllersManager.shared.getBrowserState(
            for: windowId
        ) else {
            tracker.remove(tabId: tabId, windowId: windowId)
            return
        }
        removeConversation(boundTo: tabId, in: browserState)
    }

    private func removeConversation(boundTo tabId: Int, in browserState: BrowserState) {
        guard let tab = browserState.resolveTab(tabId) else {
            tracker.remove(tabId: tabId, windowId: browserState.windowId)
            return
        }

        let tabs = affectedTabs(for: tab, in: browserState)
        tracker.remove(tabIds: Set(tabs.map(\.guid)), windowId: browserState.windowId)
        clear(tabs: tabs)
    }

    func removeConversation(boundTo identifier: String, in browserState: BrowserState) {
        guard let tab = browserState.tab(forChatIdentifier: identifier) else { return }
        guard let split = browserState.splitGroup(forTabId: tab.guid) else {
            removeConversation(boundTo: tab.guid, in: browserState)
            return
        }

        let splitTabIds = Set([split.primaryTabId, split.secondaryTabId])
        let liveSplitTabs = browserState.tabs.filter { splitTabIds.contains($0.guid) }
        let representedSplitTabs = representedTabs(
            forLiveTabs: liveSplitTabs,
            in: browserState
        )
        tracker.remove(tabId: tab.guid, windowId: browserState.windowId)

        let survivingChatTab = liveSplitTabs.first { candidate in
            candidate.guid != tab.guid &&
                browserState.aiChatTabs[browserState.getTabIdentifier(for: candidate)] != nil
        }
        if let survivingChatTab,
           let survivingState = tracker.statesByTabId[survivingChatTab.guid] {
            apply(survivingState, to: representedSplitTabs)
            return
        }

        tracker.remove(tabIds: splitTabIds, windowId: browserState.windowId)
        clear(tabs: representedSplitTabs)
    }

    func splitDidDissolve(_ split: SplitGroup, in browserState: BrowserState) {
        for tabId in [split.primaryTabId, split.secondaryTabId] {
            guard let tab = browserState.resolveTab(tabId) else {
                tracker.remove(tabId: tabId, windowId: browserState.windowId)
                continue
            }
            let representations = representedTabs(forLiveTabs: [tab], in: browserState)
            if let state = tracker.statesByTabId[tabId],
               state.windowId == browserState.windowId {
                apply(state, to: representations)
            } else {
                clear(tabs: representations)
            }
        }
    }

    func contentTabDidClose(
        _ tabId: Int,
        in browserState: BrowserState,
        migratingConversationTo destinationTabId: Int? = nil
    ) {
        let closedTabRepresentations = browserState.resolveTab(tabId).map {
            representedTabs(forLiveTabs: [$0], in: browserState)
        } ?? []

        if let destinationTabId,
           let destinationTab = browserState.resolveTab(destinationTabId),
           let state = tracker.moveState(
               from: tabId,
               to: destinationTabId,
               windowId: browserState.windowId
           ) {
            apply(
                state,
                to: representedTabs(forLiveTabs: [destinationTab], in: browserState)
            )
        } else {
            tracker.remove(tabId: tabId, windowId: browserState.windowId)
        }
        clear(tabs: closedTabRepresentations)
    }

    func removeAll() {
        tracker.removeAll()
        for controller in MainBrowserWindowControllersManager.shared.getAllWindows() {
            let state = controller.browserState
            clear(tabs: representedTabs(forLiveTabs: state.tabs, in: state))
        }
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
            tab.hasStartedChatGeneration = state.hasStartedGeneration
            tab.isPairedChatGenerating = state.active
        }
    }

    private func clear(tabs: [Tab]) {
        for tab in tabs {
            tab.hasPairedChat = false
            tab.hasStartedChatGeneration = false
            tab.isPairedChatGenerating = false
        }
    }
}
