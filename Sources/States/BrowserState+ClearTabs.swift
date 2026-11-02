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
    var closed = Set<Int>()
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
            guard let batch = pendingClearTabClosures.removeValue(forKey: id) else { continue }
            let isFirstRemoval = batch.closed.isEmpty
            batch.closed.insert(id)
            if !batch.registered {
                batch.registered = true
                registerClearTabsUndo(batch)
            }
            if isFirstRemoval {
                OverlayToastCenter.shared.showClearedTabsConfirmation(in: self)
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

    /// Chromium inserts every page, group and split in one batch and reports the
    /// final strip once, so the sidebar never passes through intermediate orders.
    private func undoClearedTabs(_ batch: ClearedTabsBatch) {
        clearTabsUndoManager.registerUndo(withTarget: self) { state in
            MainActor.assumeIsolated { state.clearAllTabs() }
        }
        clearTabsUndoManager.setActionName(Self.clearTabsActionTitle)
        pendingClearTabClosures = pendingClearTabClosures.filter { $0.value !== batch }

        let pages = Dictionary(uniqueKeysWithValues: batch.pages.filter { batch.closed.contains($0.id) }.map { ($0.id, $0) })
        guard !pages.isEmpty else { return }
        let order: [[AnyHashable: Any]] = batch.order.compactMap { id in
            if let page = pages[id] { return ["key": String(id), "url": page.url, "title": page.title] }
            return resolveTab(id) == nil ? nil : ["tabId": id]
        }
        let groups: [[AnyHashable: Any]] = batch.groups.compactMap { group in
            let keys = batch.pages.filter { $0.group == group.token && pages[$0.id] != nil }.map { String($0.id) }
            guard !keys.isEmpty else { return nil }
            if self.groups[group.token] != nil { return ["keys": keys, "tokenHex": group.token] }
            return ["keys": keys, "title": group.title, "color": group.color, "collapsed": group.collapsed]
        }
        let splits: [[AnyHashable: Any]] = batch.splits.compactMap { split in
            guard pages[split.primaryTabId] != nil, pages[split.secondaryTabId] != nil else { return nil }
            return ["primaryKey": String(split.primaryTabId), "secondaryKey": String(split.secondaryTabId),
                    "layout": split.layout.rawValue, "ratio": split.ratio]
        }

        isRestoringClearedTabs = true
        let restored = restoreTabs(order: order, groups: groups, splits: splits)
        if restored.count < pages.count {
            AppLogWarn("[ClearTabs] Restored \(restored.count) of \(pages.count) tabs")
        }
        // The inserted-tabs snapshot reaches this state on a later main-actor turn.
        Task { @MainActor [weak self] in self?.isRestoringClearedTabs = false }
    }
}
