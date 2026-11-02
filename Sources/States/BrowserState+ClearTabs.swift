// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import Cocoa

/// A window-local cleanup record. Only confirmed removals are restored; cancelled
/// beforeunload requests never become duplicate tabs. Navigation history is not saved.
final class ClearedTabsBatch {
    struct Page {
        let id: Int
        let url: String
        let title: String
        let group: String?
    }
    struct Group {
        let token: String
        let title: String
        let color: String
        let collapsed: Bool
    }
    let pages: [Page]
    let order: [Int]
    let groups: [Group]
    let splits: [SplitGroup]
    var liveIDs: [Int: Int]
    var closed = Set<Int>()
    var restored = Set<Int>()
    var registered = false

    init(tabs: [Tab], state: BrowserState) {
        pages = tabs.map { Page(id: $0.guid, url: $0.url ?? "about:blank", title: $0.title, group: $0.groupToken) }
        order = state.normalTabs.map(\.guid)
        let tokens = Set(tabs.compactMap(\.groupToken))
        groups = state.groups.values.filter { tokens.contains($0.token) }.map {
            Group(token: $0.token, title: $0.title, color: $0.color.rawValue, collapsed: $0.isCollapsed)
        }
        let ids = Set(tabs.map(\.guid))
        splits = state.splits.filter { ids.contains($0.primaryTabId) && ids.contains($0.secondaryTabId) }
        liveIDs = Dictionary(uniqueKeysWithValues: tabs.map { ($0.guid, $0.guid) })
    }
}

@MainActor
extension BrowserState {
    static var clearTabsActionTitle: String {
        NSLocalizedString("tabs.clearAll.title", value: "Clear All Tabs", comment: "Tab cleanup command - Close ordinary tabs that are not currently displayed")
    }

    var canClearAllTabs: Bool {
        normalTabs.count > 1 && !isKioskWindow && !isRestoringClearedTabs
            && !AgentSpaceManager.shared.isAgentOwned(spaceId)
    }

    var clearAllTabsCandidates: [Tab] {
        // A transient focus gap must not close the entire Space and destroy
        // the window that owns this Undo history.
        guard let foreground = focusingTab ?? tabs.first(where: \.isActive) else { return [] }
        var visible: Set<Int> = [foreground.guid]
        if let peek = visiblePeek(focusingTab: focusingTab) { visible.insert(peek.tab.guid) }
        let protected = tabCloseUnits(containing: visible)
        return ordinaryTabCloseCandidates.filter { !protected.contains($0.guid) && !isBookmarkBackedTab($0) }
    }

    func clearAllTabs() {
        guard canClearAllTabs else { return }
        let candidates = clearAllTabsCandidates
        guard !candidates.isEmpty else { return }
        let batch = ClearedTabsBatch(tabs: candidates, state: self)
        // Redo is a fresh cleanup of the current background tabs. Register its
        // inverse while UndoManager is still redoing, before async removals arrive.
        if clearTabsUndoManager.isRedoing {
            batch.registered = true
            registerClearTabsUndo(batch)
        }
        for tab in candidates { pendingClearTabClosures[tab.guid] = batch }
        closeTabs(candidates)
    }

    func recordClearedTabs(_ removedIDs: Set<Int>) {
        for id in removedIDs {
            guard let batch = pendingClearTabClosures.removeValue(forKey: id),
                  let original = batch.liveIDs.first(where: { $0.value == id })?.key else { continue }
            batch.closed.insert(original)
            if !batch.registered {
                batch.registered = true
                registerClearTabsUndo(batch)
            }
        }
    }

    private func registerClearTabsUndo(_ batch: ClearedTabsBatch) {
        clearTabsUndoManager.beginUndoGrouping()
        clearTabsUndoManager.registerUndo(withTarget: self) { state in
            MainActor.assumeIsolated { state.undoClearedTabs(batch) }
        }
        clearTabsUndoManager.setActionName(Self.clearTabsActionTitle)
        clearTabsUndoManager.endUndoGrouping()
    }

    private func undoClearedTabs(_ batch: ClearedTabsBatch) {
        clearTabsUndoManager.registerUndo(withTarget: self) { state in
            MainActor.assumeIsolated { state.clearAllTabs() }
        }
        clearTabsUndoManager.setActionName(Self.clearTabsActionTitle)
        pendingClearTabClosures = pendingClearTabClosures.filter { $0.value !== batch }
        isRestoringClearedTabs = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRestoringClearedTabs = false }
            let focusedID = self.focusingTab?.guid
            var collapsedGroups: [String: Bool] = [:]
            do {
                for page in batch.pages where batch.closed.contains(page.id) {
                    let tab = try await self.restoreClearedPage(page)
                    batch.liveIDs[page.id] = tab.guid
                    batch.closed.remove(page.id)
                    batch.restored.insert(page.id)
                }
                collapsedGroups = self.restoreClearedTabStructure(batch)
            } catch {
                AppLogWarn("[ClearTabs] Restore interrupted: \(error)")
            }
            if let focusedID, let focused = self.resolveTab(focusedID) {
                focused.webContentWrapper?.setAsActiveTab()
                self.focuseTab(focused)
            }
            // Creating a split activates its pane and expands its group. Apply
            // the saved collapsed state only after returning to the kept tab.
            for (token, collapsed) in collapsedGroups {
                ChromiumLauncher.sharedInstance().bridge?.updateTabGroupCollapsed(
                    withWindowId: Int64(self.windowId), tokenHex: token, isCollapsed: collapsed)
            }
        }
    }

    enum ClearTabsRestoreError: Error { case unavailable, timedOut }
    static let clearTabsRestorePrefix = "clear-tabs-pending:"

    /// Called before persistent binding resolution; late arrivals are closed.
    func consumeClearTabsRestoreMarker(_ tab: Tab) -> (() -> Void)? {
        guard let marker = tab.guidInLocalDB, marker.hasPrefix(Self.clearTabsRestorePrefix) else { return nil }
        tab.guidInLocalDB = nil
        tab.webContentWrapper?.updateTabCustomValue("")
        let completion = pendingClearTabRestores.removeValue(forKey: marker)
        return {
            DispatchQueue.main.async {
                if let completion { completion(tab) }
                else { tab.webContentWrapper?.close() }
            }
        }
    }

    func restoreClearedPage(_ page: ClearedTabsBatch.Page) async throws -> Tab {
        guard SpaceSessionControllersManager.shared.getBrowserState(for: windowId) === self,
              !AgentSpaceManager.shared.isAgentOwned(spaceId) else { throw ClearTabsRestoreError.unavailable }
        let marker = Self.clearTabsRestorePrefix + UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pendingClearTabRestores[marker] = { tab in
                tab.title = page.title
                continuation.resume(returning: tab)
            }
            createTab(page.url, customGuid: marker, focusAfterCreate: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard self?.pendingClearTabRestores.removeValue(forKey: marker) != nil else { return }
                continuation.resume(throwing: ClearTabsRestoreError.timedOut)
            }
        }
    }

    func restoreClearedTabStructure(_ batch: ClearedTabsBatch) -> [String: Bool] {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else { return [:] }
        var collapsedGroups: [String: Bool] = [:]
        // Restore order before joining groups or splits, whose members move as a unit.
        let order = batch.order.compactMap { original -> Int? in
            let id = batch.liveIDs[original] ?? original
            return resolveTab(id) == nil ? nil : id
        }
        for (index, id) in order.enumerated() {
            guard let current = normalTabs.firstIndex(where: { $0.guid == id }), current != index else { continue }
            moveNormalTabLocally(from: current, to: current < index ? index + 1 : index)
        }
        for group in batch.groups {
            let members = batch.pages.filter { $0.group == group.token && batch.restored.contains($0.id) }
                .compactMap { batch.liveIDs[$0.id] }.filter { resolveTab($0) != nil }
            guard !members.isEmpty else { continue }
            let token: String
            if groups[group.token] != nil {
                token = group.token
                bridge.addTabsToGroup(withWindowId: Int64(windowId), tabIds: members.map(NSNumber.init(value:)), tokenHex: token)
            } else {
                token = bridge.createGroupFromTabs(withWindowId: Int64(windowId), tabIds: members.map(NSNumber.init(value:)),
                                                   title: group.title, color: group.color)
            }
            guard !token.isEmpty else { continue }
            for id in members { applyOptimisticGroupMembership(tabId: id, newToken: token) }
            collapsedGroups[token] = group.collapsed
        }
        for split in batch.splits {
            guard batch.restored.contains(split.primaryTabId) || batch.restored.contains(split.secondaryTabId),
                  let left = batch.liveIDs[split.primaryTabId], let right = batch.liveIDs[split.secondaryTabId],
                  resolveTab(left) != nil, resolveTab(right) != nil,
                  splitGroup(forTabId: left) == nil, splitGroup(forTabId: right) == nil,
                  let id = createSplit(leftTabId: left, rightTabId: right, layout: split.layout) else { continue }
            updateSplitRatio(id, ratio: split.ratio)
        }
        return collapsedGroups
    }
}
