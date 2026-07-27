// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine

/// Describes tab-section rows whose cells need extra rebinding after the
/// root sidebar snapshot has been applied.
struct TabSectionChange {
    /// Whether the ordered root rows changed by stable id or object identity.
    /// A false value lets the consumer keep group/split cell updates local
    /// without rebuilding the bookmark-heavy shared outline snapshot.
    let rootItemsChanged: Bool
    /// Group tokens whose live `state.normalTabs.filter { groupToken == token }`
    /// child list changed (membership added/removed or intra-group reorder).
    /// The consumer updates only these wrappers' cells — adding an
    /// ungrouped tab leaves this empty so unrelated groups don't repaint.
    let affectedGroupTokens: Set<String>
    /// Split ids whose merged pair row kept its identity but changed pane
    /// membership (drag-to-replace swaps one pane's Tab object in place on
    /// the cached `SplitPairSidebarItem`). The row id is keyed on the split
    /// id alone, so the root snapshot can keep the same row identity while
    /// the consumer re-binds these rows' cells so titles/favicons/subscriptions
    /// attach to the new Tab.
    let affectedSplitIds: Set<String>

    /// True when this update was driven synchronously by a restored-window
    /// snapshot transaction (T3B): the consumer applies the root snapshot
    /// without animations so the list lands fully formed in the same
    /// main-thread turn. Ordinary interactive updates leave this false.
    let isRestoreTransaction: Bool

    init(rootItemsChanged: Bool,
         affectedGroupTokens: Set<String>,
         affectedSplitIds: Set<String>,
         isRestoreTransaction: Bool = false) {
        self.rootItemsChanged = rootItemsChanged
        self.affectedGroupTokens = affectedGroupTokens
        self.affectedSplitIds = affectedSplitIds
        self.isRestoreTransaction = isRestoreTransaction
    }

    /// PHI-1099's outer-outline repair is safe only when the root change is
    /// isolated from group membership and split-pair mutations that the outer
    /// snapshot intentionally does not represent.
    var allowsInsertedRootTabLayoutRepair: Bool {
        rootItemsChanged && affectedGroupTokens.isEmpty && affectedSplitIds.isEmpty
    }
}

class TabSectionController: NSObject {
    private var cancellables = Set<AnyCancellable>()
    /// Per-group inner subscriptions. Refreshed whenever `browserState.groups`
    /// changes (groups created/closed) so that title/color/isCollapsed
    /// edits and membership-mutation `objectWillChange.send()` calls
    /// (kJoined/kLeft/pending-claim drain) trigger tab-section reconciliation.
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

    /// Per-`SplitGroup.id` stable wrapper for the merged split-pair row.
    /// `NSOutlineView` keys its drop-feedback / expansion / row-selection
    /// caches on object identity; without this cache, every `buildItems`
    /// pass allocates a fresh `SplitPairSidebarItem` and AppKit's
    /// identity lookups silently no-op, manifesting most visibly as the
    /// `.regular` between-row drop indicator failing to paint above/below
    /// a split-pair row even after `setDropItem(nil, dropChildIndex:)`
    /// redirects the proposal. `leftTab` / `rightTab` are mutable
    /// properties precisely so the wrapper can be re-resolved in place
    /// after a "Reverse Panes" swap (see `SidebarItem.swift`).
    /// Evicted in lock-step with `groupWrappers` when the underlying
    /// split group disappears.
    private var splitPairWrappers: [String: SplitPairSidebarItem] = [:]

    /// Per-token ordered guid list captured from the previous frame's
    /// `normalTabs`. Used to detect membership / order changes inside any
    /// given group so the consumer can update exactly the affected wrappers
    /// (and leave unrelated groups untouched on edits like creating a new
    /// ungrouped tab).
    private var previousGroupMembers: [String: [Int]] = [:]

    /// Per-split [left guid, right guid] captured from the previous frame's
    /// emitted pair rows. Compared frame-over-frame to detect a pane being
    /// replaced in place — the pair row's id survives the swap, so without
    /// this the diff path never re-binds the cell to the new Tab.
    private var previousSplitMembers: [String: [Int]] = [:]

    /// Identity snapshot of the `normalTabs` array a restore-transaction
    /// signal already rendered synchronously. The @Published pipeline still
    /// delivers that same publish one main-queue turn later; matching it
    /// here skips the redundant rebuild. One-shot: ANY delivery clears it,
    /// so a stale token can never suppress a future legitimate update.
    private var syncHandledNormalTabs: [Tab]?

    weak var delegate: TabSectionDelegate?
    var browserState: BrowserState? {
        didSet {
            setupBindings()
        }
    }

    init(state: BrowserState? = nil) {
        self.browserState = state
        super.init()
        refreshTabItems([])
    }

    private func setupBindings() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        groupContentsCancellables.forEach { $0.cancel() }
        groupContentsCancellables.removeAll()

        guard let browserState else {
            tabItems = []
            previousGroupMembers = [:]
            previousSplitMembers = [:]
            groupWrappers.removeAll()
            splitPairWrappers.removeAll()
            return
        }

        // Sync tabItems with current state immediately, without notifying
        // the delegate. This prevents a spurious tabSectionDidUpdate call
        // (from @Published's synchronous initial delivery) that races with the
        // refreshAllItems() call in viewWillAppear and causes duplicate cell creation.
        let currentTabs = browserState.normalTabs
        let initialItems = buildItems(from: currentTabs, groups: browserState.groups, state: browserState)
        tabItems = initialItems
        previousGroupMembers = Self.computeGroupMembers(tabs: currentTabs)
        previousSplitMembers = Self.computeSplitMembers(items: initialItems)

        // dropFirst() skips the initial synchronous delivery we already handled
        // above. receive(on: .main) defers until after @Published's willSet
        // settles — same reason as the $groups subscription below — so that
        // TabGroupSidebarItem.childrenItems (queried by NSOutlineView during
        // reloadItem) reads the post-mutation normalTabs.
        browserState.$normalTabs
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tabs in
                guard let self else { return }
                if let handled = self.syncHandledNormalTabs {
                    self.syncHandledNormalTabs = nil
                    if handled.count == tabs.count,
                       zip(handled, tabs).allSatisfy({ $0 === $1 }) {
                        return
                    }
                }
                self.refreshTabItems(tabs)
            }
            .store(in: &cancellables)

        // Restore-transaction signal: synchronous by design (no
        // receive(on:), mirroring the $isInPlaceholderMode precedent) so the
        // one root snapshot lands in the same main-thread turn as the state
        // application (T3B amendment 1). The trailing @Published delivery of
        // the same publish is suppressed one-shot via
        // `syncHandledNormalTabs`.
        browserState.restoredWindowTransactionSignal
            .sink { [weak self] in
                self?.applyRestoredTransactionRefresh()
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
                self.refreshTabItems(self.browserState?.normalTabs ?? [])
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

        // Splits collapse two normal-tab rows into a single
        // `SplitPairSidebarItem`. The tab list itself doesn't change on
        // split create/disband, so rebuild the section so the item
        // count adjusts when a pair forms or splits.
        browserState.$splits
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshTabItems(self.browserState?.normalTabs ?? [])
            }
            .store(in: &cancellables)
    }

    /// (Re)subscribes to every current `WebContentGroupInfo`'s
    /// `objectWillChange`. Any change to title / color / isCollapsed plus
    /// membership-driven nudges from `BrowserState.handleTabJoined/Left/
    /// drainPendingGroupClaim` trigger reconciliation on the next runloop tick
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
                    self.refreshTabItems(self.browserState?.normalTabs ?? [])
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
        let liveSplitIds = Set(state.splits.map(\.id))
        splitPairWrappers = splitPairWrappers.filter { liveSplitIds.contains($0.key) }

        var items: [SidebarItem] = [newTabButton]
        var emittedGroupTokens = Set<String>()
        // Tab ids consumed by an emitted SplitPairSidebarItem. When we
        // iterate to the second pane of a split we skip it so the pair
        // collapses into one row in the sidebar.
        var consumedSplitTabIds = Set<Int>()

        for tab in tabs {
            if consumedSplitTabIds.contains(tab.guid) {
                continue
            }
            // Collapse non-pinned splits (when not inside a tab group) into
            // a single merged row. Pinned splits are surfaced by the
            // pinned-tab section; in-group splits stay under their group
            // wrapper for now.
            if tab.groupToken == nil,
               let group = state.splitGroup(forTabId: tab.guid),
               !group.isPinned,
               let partnerId = group.partnerTabId(of: tab.guid),
               let partner = tabs.first(where: { $0.guid == partnerId }),
               partner.groupToken == nil {
                let leftTab: Tab
                let rightTab: Tab
                if let myIdx = tabs.firstIndex(where: { $0.guid == tab.guid }),
                   let partnerIdx = tabs.firstIndex(where: { $0.guid == partnerId }),
                   myIdx < partnerIdx {
                    leftTab = tab
                    rightTab = partner
                } else {
                    leftTab = partner
                    rightTab = tab
                }
                // Reuse the cached wrapper so NSOutlineView's identity-keyed
                // tracking (drop feedback, expansion state, selection) survives
                // every `buildItems` rebuild. The `id` is keyed on `group.id`
                // alone, so updating `leftTab` / `rightTab` in place is correct
                // for "Reverse Panes" swaps too.
                let pair: SplitPairSidebarItem
                if let cached = splitPairWrappers[group.id] {
                    cached.leftTab = leftTab
                    cached.rightTab = rightTab
                    cached.browserState = state
                    pair = cached
                } else {
                    pair = SplitPairSidebarItem(
                        groupId: group.id,
                        leftTab: leftTab,
                        rightTab: rightTab,
                        browserState: state)
                    splitPairWrappers[group.id] = pair
                }
                items.append(pair)
                consumedSplitTabIds.insert(tab.guid)
                consumedSplitTabIds.insert(partnerId)
                continue
            }
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

    /// Rebuilds the tab section synchronously off the restore-transaction
    /// signal. Reads `normalTabs` directly — the signal fires after the
    /// transaction's single publish, so the value is already written — and
    /// arms the one-shot suppression for the trailing @Published delivery.
    private func applyRestoredTransactionRefresh() {
        guard let browserState else { return }
        let tabs = browserState.normalTabs
        syncHandledNormalTabs = tabs
        refreshTabItems(tabs, isRestoreTransaction: true)
    }

    private func refreshTabItems(_ tabs: [Tab], isRestoreTransaction: Bool = false) {
        let previousItems = tabItems
        guard let browserState else {
            tabItems = []
            previousGroupMembers = [:]
            previousSplitMembers = [:]
            delegate?.tabSectionDidUpdate(with: TabSectionChange(
                rootItemsChanged: !previousItems.isEmpty,
                affectedGroupTokens: [],
                affectedSplitIds: [],
                isRestoreTransaction: isRestoreTransaction
            ))
            return
        }
        let groups = browserState.groups
        let items = buildItems(from: tabs, groups: groups, state: browserState)
        let newGroupMembers = Self.computeGroupMembers(tabs: tabs)
        let affectedTokens = Self.affectedGroupTokens(old: previousGroupMembers,
                                                      new: newGroupMembers)
        let newSplitMembers = Self.computeSplitMembers(items: items)
        let affectedSplits = Self.affectedSplitIds(old: previousSplitMembers,
                                                   new: newSplitMembers)
        let rootItemsChanged = Self.rootItemsChanged(from: previousItems, to: items)

        self.tabItems = items
        self.previousGroupMembers = newGroupMembers
        self.previousSplitMembers = newSplitMembers

        delegate?.tabSectionDidUpdate(with: TabSectionChange(
            rootItemsChanged: rootItemsChanged,
            affectedGroupTokens: affectedTokens,
            affectedSplitIds: affectedSplits,
            isRestoreTransaction: isRestoreTransaction
        ))
    }

    /// Compares the exact identity contract used by the outline snapshot.
    /// Stable ids preserve row location, while stable object identity keeps
    /// the data source and AppKit's identity-keyed row state aligned.
    static func rootItemsChanged(from oldItems: [SidebarItem], to newItems: [SidebarItem]) -> Bool {
        guard oldItems.count == newItems.count else { return true }
        return zip(oldItems, newItems).contains { oldItem, newItem in
            oldItem.id != newItem.id || ObjectIdentifier(oldItem) != ObjectIdentifier(newItem)
        }
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

    /// Snapshot of each emitted pair row's [left guid, right guid]. Compared
    /// frame-over-frame to identify pair rows whose membership changed while
    /// their id (the split id) survived — drag-to-replace and the
    /// reverse-panes swap both mutate the cached wrapper in place.
    private static func computeSplitMembers(items: [SidebarItem]) -> [String: [Int]] {
        var result: [String: [Int]] = [:]
        for case let pair as SplitPairSidebarItem in items {
            result[pair.groupId] = [pair.leftTab.guid, pair.rightTab.guid]
        }
        return result
    }

    /// Split ids present in both frames whose pane guids changed. Ids only
    /// in one frame surface as row insertions/removals in the root snapshot
    /// and rebuild their cell anyway.
    private static func affectedSplitIds(old: [String: [Int]],
                                         new: [String: [Int]]) -> Set<String> {
        var ids: Set<String> = []
        for id in Set(old.keys).intersection(new.keys) where old[id] != new[id] {
            ids.insert(id)
        }
        return ids
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
