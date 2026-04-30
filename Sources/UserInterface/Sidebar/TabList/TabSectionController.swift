// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine

/// Describes an incremental change in the tab section.
struct TabSectionChange {
    /// Inserted tab indices relative to `tabItems`, including `newTabButton`.
    let insertedIndices: IndexSet
    /// Removed tab indices relative to the previous `tabItems`.
    let removedIndices: IndexSet
    /// A single-tab move operation relative to `tabItems`, including `newTabButton`.
    let moveOperation: (from: Int, to: Int)?
    /// Whether a full reload is required.
    let needsFullReload: Bool
    /// Group tokens whose live `state.normalTabs.filter { groupToken == token }`
    /// child list changed (membership added/removed or intra-group reorder).
    /// The consumer reloads only these wrappers' children — adding an
    /// ungrouped tab leaves this empty so unrelated groups don't repaint.
    let affectedGroupTokens: Set<String>
}

class TabSectionController: NSObject {
    private var cancellables = Set<AnyCancellable>()
    /// Per-group inner subscriptions. Refreshed whenever `browserState.groups`
    /// changes (groups created/closed) so that title/color/isCollapsed
    /// edits and membership-mutation `objectWillChange.send()` calls
    /// (kJoined/kLeft/pending-claim drain) trigger an outline rebuild.
    private var groupContentsCancellables = Set<AnyCancellable>()

    private(set) var tabItems: [SidebarItem] = []
    private let newTabButton = NewTabButtonItem()

    /// Cache of group-row wrappers keyed by Chromium token. NSOutlineView
    /// keys expand state on object identity (===), and NSMenuItem.target is
    /// weak; rebuilding wrappers on every refresh would (a) reset disclosure
    /// state and (b) silently nil-out an open right-click menu's target.
    /// Wrappers are evicted only when their group disappears from
    /// `BrowserState.groups`.
    private var groupWrappers: [String: TabGroupSidebarItem] = [:]

    /// Previous root-level item ids used to compute diffs. Holds tab guid
    /// (`Int`) for ungrouped tabs and group token (`String`) for group rows.
    private var previousItemIds: [AnyHashable] = []

    /// Per-token ordered guid list captured from the previous frame's
    /// `normalTabs`. Used to detect membership / order changes inside any
    /// given group so the consumer can reload exactly the affected wrappers
    /// (and leave unrelated groups untouched on edits like creating a new
    /// ungrouped tab).
    private var previousGroupMembers: [String: [Int]] = [:]

    weak var delegate: TabSectionDelegate?
    var browserState: BrowserState? {
        didSet {
            setupBindings()
        }
    }

    init(state: BrowserState? = nil) {
        self.browserState = state
        super.init()
        refreshTabItems([], isInitial: true)
    }

    private func setupBindings() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        groupContentsCancellables.forEach { $0.cancel() }
        groupContentsCancellables.removeAll()

        guard let browserState else {
            tabItems = []
            previousItemIds = []
            previousGroupMembers = [:]
            groupWrappers.removeAll()
            return
        }

        // Sync tabItems and previousItemIds with current state immediately, without
        // notifying the delegate. This prevents a spurious tabSectionDidUpdate call
        // (from @Published's synchronous initial delivery) that races with the
        // refreshAllItems() call in viewWillAppear and causes duplicate cell creation.
        let currentTabs = browserState.normalTabs
        let initialItems = buildItems(from: currentTabs, groups: browserState.groups, state: browserState)
        tabItems = initialItems
        previousItemIds = initialItems.map { $0.id }
        previousGroupMembers = Self.computeGroupMembers(tabs: currentTabs)

        // dropFirst() skips the initial synchronous delivery we already handled above.
        browserState.$normalTabs
            .dropFirst()
            .sink { [weak self] tabs in
                self?.refreshTabItems(tabs, isInitial: false)
            }
            .store(in: &cancellables)

        // Top-level group dict changes (kCreated / kClosed). The dispatch via
        // DispatchQueue.main is required because @Published fires during
        // willSet — by the time `receive(on:)` re-emits, the new dict has
        // been written, so subsequent reads of `browserState.groups` are
        // consistent.
        browserState.$groups
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.subscribeToGroupContents()
                self.refreshTabItems(self.browserState?.normalTabs ?? [], isInitial: false)
            }
            .store(in: &cancellables)

        // Initial inner-group subscription (covers groups already present
        // when the controller takes a state).
        subscribeToGroupContents()

        browserState.$focusingTab
            .dropFirst()
            .sink { [weak self] focusingTab in
                self?.delegate?.focusingTabChanged(focusingTab)
            }
            .store(in: &cancellables)
    }

    /// (Re)subscribes to every current `WebContentGroupInfo`'s
    /// `objectWillChange`. Any change to title / color / isCollapsed plus
    /// membership-driven nudges from `BrowserState.handleTabJoined/Left/
    /// drainPendingGroupClaim` trigger a rebuild on the next runloop tick
    /// (deferral matters because objectWillChange fires before the new
    /// value is stored).
    private func subscribeToGroupContents() {
        groupContentsCancellables.forEach { $0.cancel() }
        groupContentsCancellables.removeAll()
        guard let browserState else { return }
        for info in browserState.groups.values {
            info.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    guard let self else { return }
                    self.refreshTabItems(self.browserState?.normalTabs ?? [], isInitial: false)
                }
                .store(in: &groupContentsCancellables)
        }
    }

    /// Folds `tabs` into root-level items. Each tab-group token is emitted
    /// **at most once**, anchored at the position of its first member in
    /// `tabs`; same-token tabs encountered later are skipped at the root
    /// level (they appear as children via the group wrapper's live
    /// `state.normalTabs.filter { groupToken == token }` resolution).
    ///
    /// This deliberately does NOT rely on Chromium's contiguity invariant
    /// (spec § 6 約束 1) holding on the Mac side at every moment: between
    /// kMoved and kJoined for "tab joined existing group", `normalTabs`
    /// can transiently show a same-token tab dangling outside the group's
    /// run (e.g. `[g1tab1, g2tab1, T]` where T is now in G1 but hasn't
    /// been physically moved yet). The previous "contiguous run flush"
    /// algorithm would emit G1 twice in that window. The dedup set keeps
    /// the wrapper count correct in transient states; once normalTabs
    /// reorders the result is the same.
    ///
    /// Tabs with `groupToken` set but no matching entry in `groups` are
    /// rendered flat as a defensive fallback (kJoined-before-kCreated
    /// races; `handleTabJoinedGroup` stashes such claims and replays them
    /// when kCreated arrives).
    private func buildItems(from tabs: [Tab],
                            groups: [String: WebContentGroupInfo],
                            state: BrowserState) -> [SidebarItem] {
        // Evict cached wrappers for groups that no longer exist before we
        // start building (so menu actions on a dead wrapper still see a
        // nil bridge result, not a stale-but-live object).
        groupWrappers = groupWrappers.filter { groups[$0.key] != nil }

        var items: [SidebarItem] = [newTabButton]
        var emittedGroupTokens = Set<String>()

        for tab in tabs {
            guard let token = tab.groupToken else {
                items.append(tab)
                continue
            }
            guard let info = groups[token] else {
                // Race fallback — keep the tab reachable.
                items.append(tab)
                continue
            }
            if emittedGroupTokens.contains(token) {
                // Already represented by an earlier group wrapper; this
                // tab will surface as a child via dynamic resolution.
                continue
            }
            let wrapper = groupWrappers[token]
                ?? TabGroupSidebarItem(group: info, browserState: state)
            groupWrappers[token] = wrapper
            items.append(wrapper)
            emittedGroupTokens.insert(token)
        }
        return items
    }

    private func refreshTabItems(_ tabs: [Tab], isInitial: Bool) {
        guard let browserState else {
            tabItems = []
            previousItemIds = []
            previousGroupMembers = [:]
            delegate?.tabSectionDidUpdate(with: TabSectionChange(
                insertedIndices: [],
                removedIndices: [],
                moveOperation: nil,
                needsFullReload: true,
                affectedGroupTokens: []
            ))
            return
        }
        let groups = browserState.groups
        let items = buildItems(from: tabs, groups: groups, state: browserState)
        let newIds = items.map { $0.id }
        let newGroupMembers = Self.computeGroupMembers(tabs: tabs)
        let affectedTokens = Self.affectedGroupTokens(old: previousGroupMembers,
                                                      new: newGroupMembers)

        // Single diff path for all cases (with or without groups). Group
        // rows participate as ordinary root-level ids (their token), so
        // `computeFlatChange` correctly emits insertions/removals when a
        // group is created/closed and moveOperation when a group row
        // reorders past an ungrouped tab. Tab join/leave a still-existing
        // group leaves the group's token in both frames; only the moved
        // tab's id surfaces in the root diff. The consumer reloads exactly
        // the wrappers listed in `affectedGroupTokens` so unrelated edits
        // (e.g. creating an ungrouped tab) do not repaint other groups,
        // and we never call `reloadData()` — which would also rebuild the
        // bookmark section above and cause a visible flicker there.
        let change: TabSectionChange
        if isInitial || delegate == nil {
            change = TabSectionChange(insertedIndices: [],
                                      removedIndices: [],
                                      moveOperation: nil,
                                      needsFullReload: true,
                                      affectedGroupTokens: [])
        } else {
            change = computeFlatChange(oldIds: previousItemIds,
                                       newIds: newIds,
                                       affectedGroupTokens: affectedTokens)
        }

        self.tabItems = items
        self.previousItemIds = newIds
        self.previousGroupMembers = newGroupMembers

        delegate?.tabSectionDidUpdate(with: change)
    }

    /// Snapshot of each group's ordered guid list. Compared frame-over-frame
    /// to identify which wrappers need a children reload — order matters
    /// because intra-group reorder also requires a refresh.
    private static func computeGroupMembers(tabs: [Tab]) -> [String: [Int]] {
        var result: [String: [Int]] = [:]
        for tab in tabs {
            guard let token = tab.groupToken else { continue }
            result[token, default: []].append(tab.guid)
        }
        return result
    }

    private static func affectedGroupTokens(old: [String: [Int]],
                                            new: [String: [Int]]) -> Set<String> {
        var tokens: Set<String> = []
        for token in Set(old.keys).union(new.keys) where old[token] != new[token] {
            tokens.insert(token)
        }
        return tokens
    }

    private func computeFlatChange(oldIds: [AnyHashable],
                                   newIds: [AnyHashable],
                                   affectedGroupTokens: Set<String>) -> TabSectionChange {
        let oldSet = Set(oldIds)
        let newSet = Set(newIds)

        let insertedIds = newSet.subtracting(oldSet)
        let removedIds = oldSet.subtracting(newSet)

        let commonIds = oldSet.intersection(newSet)
        let oldCommonOrder = oldIds.filter { commonIds.contains($0) }
        let newCommonOrder = newIds.filter { commonIds.contains($0) }

        if oldCommonOrder != newCommonOrder {
            if insertedIds.isEmpty && removedIds.isEmpty {
                if let moveOp = detectSingleMove(oldIds: oldIds, newIds: newIds) {
                    return TabSectionChange(
                        insertedIndices: [],
                        removedIndices: [],
                        moveOperation: (from: moveOp.from, to: moveOp.to),
                        needsFullReload: false,
                        affectedGroupTokens: affectedGroupTokens
                    )
                }
            }
            return TabSectionChange(insertedIndices: [],
                                    removedIndices: [],
                                    moveOperation: nil,
                                    needsFullReload: true,
                                    affectedGroupTokens: affectedGroupTokens)
        }

        var insertedIndices = IndexSet()
        for (index, id) in newIds.enumerated() where insertedIds.contains(id) {
            insertedIndices.insert(index)
        }

        var removedIndices = IndexSet()
        for (index, id) in oldIds.enumerated() where removedIds.contains(id) {
            removedIndices.insert(index)
        }

        return TabSectionChange(
            insertedIndices: insertedIndices,
            removedIndices: removedIndices,
            moveOperation: nil,
            needsFullReload: false,
            affectedGroupTokens: affectedGroupTokens
        )
    }
    
    /// Detect whether the change can be represented as a single move.
    /// - Parameters:
    ///   - oldIds: Item ids before the move.
    ///   - newIds: Item ids after the move.
    /// - Returns: The `(from, to)` indices when a single move is detected.
    private func detectSingleMove(oldIds: [AnyHashable], newIds: [AnyHashable]) -> (from: Int, to: Int)? {
        guard oldIds.count == newIds.count else { return nil }

        for from in 0..<oldIds.count {
            for to in 0..<oldIds.count where from != to {
                var simulated = oldIds
                let item = simulated.remove(at: from)
                simulated.insert(item, at: to)
                if simulated == newIds {
                    return (from: from, to: to)
                }
            }
        }

        return nil
    }
    
    func activateTab(_ tab: Tab) {
        tab.makeSelfActive()
    }
    
    func closeTab(_ tab: Tab) {
        tab.close()
    }
    
    func moveTab(_ tab: Tab, to newIndex: Int) {
        ensureBrowsersState()?.move(tab: tab, to: newIndex, selectAfterMove: tab.isActive)
    }
    
    private func ensureBrowsersState() -> BrowserState? {
        guard let browserState else {
            AppLogWarn("browser state is nil!")
            return nil
        }
        return browserState
    }
    
    // MARK: - Drag and Drop Support
    
    func canReorderTabs() -> Bool {
        return true
    }
    
    func handleTabDrop(draggedTab: Tab, destinationIndex: Int) -> Bool {
        guard let currentIndex = browserState?.normalTabs.firstIndex(of: draggedTab) else {
            return false
        }
        
        // Don't move if dropping at the same position
        if currentIndex == destinationIndex {
            return false
        }
        
        browserState?.moveNormalTabLocally(from: currentIndex, to: destinationIndex)
        return true
    }
    
    func canAcceptTabForBookmarkCreation(_ tab: Tab) -> Bool {
        return tab.url != nil
    }
}

protocol TabSectionDelegate: AnyObject {
    func tabSectionDidUpdate(with change: TabSectionChange)
    func focusingTabChanged(_ tab: Tab?)
}
