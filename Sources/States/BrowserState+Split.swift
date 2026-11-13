// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Cocoa

/// Orientation of a Chromium split.
/// Serialized over the bridge as `"vertical"` / `"horizontal"`.
enum SplitLayout: String {
    /// Side-by-side columns, divided by vertical bars.
    case vertical
    /// Stacked rows, divided by horizontal bars.
    case horizontal

    /// Returns the other supported orientation. `vertical` is side-by-side
    /// and `horizontal` is stacked because the cases name the divider axis.
    var toggled: SplitLayout {
        self == .vertical ? .horizontal : .vertical
    }

    /// Parse a bridge-supplied layout string. Returns nil on unknown values
    /// so callers can log + decide whether to fall back rather than silently
    /// mis-orient a split (a horizontal split rendered vertical, etc.).
    init?(bridgeString: String) {
        guard let layout = SplitLayout(rawValue: bridgeString) else { return nil }
        self = layout
    }
}

/// Reserved customGuid markers stamped on a tab while a split is mid-flight.
/// They masquerade as `guidInLocalDB` from creation until one of the three
/// consumers in `handleNewTabFromChromium` — `consumePendingSplitPartner`,
/// `consumePendingPrimarySplit`, or `consumePendingSplitSlotSwap` — clears
/// them on both Swift and Chromium sides. Each consumer clears the marker
/// whenever its prefix matches, even when the pending record has already
/// expired, so a late echo can't leave the marker latched.
///
/// IMPORTANT: never compare a `guidInLocalDB` for emptiness alone — these
/// markers are non-empty but do not represent a real DB binding. Always go
/// through `match(...)` so future paths can't drift into "non-empty == real
/// binding" assumptions.
enum SplitPendingGuid {
    /// Marker for a tab being opened as a pane beside an existing tab
    /// (right-click "Open as Split") or into an existing split ("Split with
    /// New Tab" on a split, an edge drop on a split). Consumed by
    /// `consumePendingSplitPartner`.
    case partner
    /// Marker for a tab being opened as the *primary* pane of a pending
    /// split (bookmark "Open as Split"). Consumed by
    /// `consumePendingPrimarySplit`.
    case primary
    /// Marker for a tab being opened to *replace* one pane of an existing
    /// split (drag bookmark / closed-pinned onto a split pane). Consumed by
    /// `consumePendingSplitSlotSwap`.
    case swapSlot

    private static let partnerPrefix = "split-pending:"
    private static let primaryPrefix = "split-primary-pending:"
    private static let swapSlotPrefix = "split-swap-pending:"

    private var prefix: String {
        switch self {
        case .partner: return Self.partnerPrefix
        case .primary: return Self.primaryPrefix
        case .swapSlot: return Self.swapSlotPrefix
        }
    }

    /// Returns a fresh marker string suitable for use as a tab's customGuid.
    func mint() -> String { "\(prefix)\(UUID().uuidString)" }

    /// True when `raw` is a non-nil marker of this kind.
    func matches(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return raw.hasPrefix(prefix)
    }
}

/// Where a tab sits within its split, ordered by tab-strip index. Used by the
/// sidebar and the tab strip to round the merged bar's ends only.
enum SplitPanePosition: Equatable {
    /// Lowest tab-strip index — top cell in the sidebar, leftmost in the strip.
    case first
    /// Between two other panes (three- and four-pane splits).
    case middle
    /// Highest tab-strip index.
    case last
}

/// Window-scoped mirror of a Chromium `SplitTabId`.
/// The IDs are opaque strings (Token::ToString) — do not parse them.
///
/// A split holds two to `maxPaneCount` panes in slot order: slot 0 is the
/// left column of a vertical split and the top row of a horizontal one.
/// Chromium owns the order; `tabIds` is whatever it last reported.
struct SplitGroup: Equatable {
    /// The most panes a split holds, matching Chromium's
    /// `split_tabs::kMaxSplitPaneCount`.
    static let maxPaneCount = 4

    let id: String
    /// Pane tab ids in slot order.
    var tabIds: [Int]
    var layout: SplitLayout
    /// Each pane's share of the split axis in slot order, summing to 1.
    var fractions: [Double]
    /// Pin flag for the split as a unit. Toggled via `toggleSplitPinStatus`.
    /// When true the merged sidebar bar shows a pin indicator; the split
    /// otherwise behaves identically. Window-scoped, not persisted.
    var isPinned: Bool = false

    init(id: String,
         tabIds: [Int],
         layout: SplitLayout,
         fractions: [Double],
         isPinned: Bool = false) {
        self.id = id
        self.tabIds = tabIds
        self.layout = layout
        self.fractions = Self.normalizedFractions(fractions, paneCount: tabIds.count)
        self.isPinned = isPinned
    }

    var paneCount: Int { tabIds.count }
    var isPair: Bool { tabIds.count == 2 }
    var canAddPane: Bool { tabIds.count < Self.maxPaneCount }
    var firstTabId: Int { tabIds[0] }
    var lastTabId: Int { tabIds[tabIds.count - 1] }

    /// The two panes of a pair, nil for a wider split. Travel Back, the one
    /// persisted surface still shaped as a pair, takes only pairs.
    var pair: (primary: Int, secondary: Int)? {
        guard tabIds.count == 2 else { return nil }
        return (tabIds[0], tabIds[1])
    }

    /// A pair's divider position: the first pane's share. Nil for a wider
    /// split, whose panes each have a share in `fractions`.
    var pairRatio: Double? {
        guard tabIds.count == 2 else { return nil }
        return fractions[0]
    }

    func contains(tabId: Int) -> Bool {
        tabIds.contains(tabId)
    }

    /// The slot `tabId` occupies, or nil when it is not a pane.
    func slot(of tabId: Int) -> Int? {
        tabIds.firstIndex(of: tabId)
    }

    /// Every other pane, in slot order; empty when `tabId` is not a pane.
    func otherTabIds(of tabId: Int) -> [Int] {
        guard contains(tabId: tabId) else { return [] }
        return tabIds.filter { $0 != tabId }
    }

    /// The other pane of a pair. Nil for a wider split or a non-member, so a
    /// caller that only ever handles pairs falls out cleanly.
    func pairPartnerTabId(of tabId: Int) -> Int? {
        guard tabIds.count == 2, let slot = slot(of: tabId) else { return nil }
        return tabIds[1 - slot]
    }

    static func equalFractions(paneCount: Int) -> [Double] {
        let count = max(1, paneCount)
        return Array(repeating: 1.0 / Double(count), count: count)
    }

    /// One share per pane: the given shares when they fit (normalised to sum
    /// to 1), equal shares otherwise.
    static func normalizedFractions(_ fractions: [Double], paneCount: Int) -> [Double] {
        guard fractions.count == paneCount, paneCount > 0,
              fractions.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return equalFractions(paneCount: paneCount)
        }
        let sum = fractions.reduce(0, +)
        guard sum > 0 else { return equalFractions(paneCount: paneCount) }
        return fractions.map { $0 / sum }
    }
}

extension BrowserState {
    // MARK: - Queries

    func splitGroup(forTabId tabId: Int) -> SplitGroup? {
        splits.first { $0.contains(tabId: tabId) }
    }

    func splitGroup(forId splitId: String) -> SplitGroup? {
        splits.first { $0.id == splitId }
    }

    /// Position of a tab within its split, as ordered by the tab strip.
    /// Returns nil if not in a split, a pane is missing, or the panes are not
    /// at consecutive indices in slot order — the merged-bar styling derived
    /// from this value assumes physical adjacency, so a transiently-separated
    /// split must fall back to plain tab rendering rather than paint a
    /// misleading partial bar with a tab sitting between the panes.
    func splitPanePosition(forTabId tabId: Int) -> SplitPanePosition? {
        guard let group = splitGroup(forTabId: tabId),
              let slot = group.slot(of: tabId) else { return nil }
        var indices: [Int] = []
        for id in group.tabIds {
            guard let index = normalTabs.firstIndex(where: { $0.guid == id }) else { return nil }
            indices.append(index)
        }
        for (offset, index) in indices.enumerated() where index != indices[0] + offset {
            return nil
        }
        if slot == 0 { return .first }
        if slot == group.paneCount - 1 { return .last }
        return .middle
    }

    /// Whole-splitview view of a sidebar cell. Returned by
    /// `BrowserState.splitMembership(forCellTab:)`, which centralizes the
    /// three-way detection — by Chromium tab id, by `guidInLocalDB` when
    /// the cell renders a pinned record whose pane is open, and by
    /// persisted `splitPartnerGuid` when both panes are closed.
    ///
    /// Surfaces that act on a splitview as one unit (right-click menu,
    /// drag/drop, duplicate, bookmark) consume the fields they need
    /// instead of repeating the lookup chain.
    struct SplitMembership {
        /// Live `SplitGroup` covering every pane, when all panes are
        /// currently open Chromium tabs. `nil` for closed pinned splits.
        let liveGroup: SplitGroup?
        /// Persisted DB guids for pinned splits (live or closed), in
        /// pinned-grid order. `nil` for non-pinned live splits.
        let pinnedDBGuids: [String]?
        /// Display tabs for the panes in on-screen order (live tabs when
        /// open, pinned records otherwise). Two to four entries.
        let panes: [Tab]

        /// True iff the cell belongs to a pinned split (live or closed).
        var isPinned: Bool { pinnedDBGuids != nil }
        var paneCount: Int { panes.count }
        var firstPane: Tab { panes[0] }
        var lastPane: Tab { panes[panes.count - 1] }
    }

    /// Resolves the splitview the right-clicked / dragged sidebar cell
    /// belongs to, regardless of whether the cell renders a live tab, a
    /// pinned record with both panes live, or a pinned record whose
    /// panes are both closed. Returns `nil` when `cellTab` is not part
    /// of any split.
    ///
    /// See `SplitMembership` for the semantics of the returned fields.
    func splitMembership(forCellTab cellTab: Tab) -> SplitMembership? {
        // 1) Live group when the cell is a live Chromium tab.
        if let group = splitGroup(forTabId: cellTab.guid) {
            return liveGroupMembership(group)
        }
        // 2) Cell renders a pinned record (synthetic `guid`); resolve via
        //    `guidInLocalDB` so an open pane still routes to the live group.
        if let dbGuid = cellTab.guidInLocalDB, !dbGuid.isEmpty {
            if let liveTab = tabs.first(where: { $0.guidInLocalDB == dbGuid }),
               let group = splitGroup(forTabId: liveTab.guid) {
                return liveGroupMembership(group)
            }
            // 3) Closed pinned split — no live group, but `splitPartnerGuid`
            //    on the persisted record identifies the pair.
            if let pinnedSelf = pinnedTabs.first(where: { $0.guidInLocalDB == dbGuid }) {
                return closedPinnedMembership(pinnedSelf: pinnedSelf)
            }
        }
        return nil
    }

    private func liveGroupMembership(_ group: SplitGroup) -> SplitMembership? {
        var panes: [Tab] = []
        for tabId in group.tabIds {
            guard let tab = tabs.first(where: { $0.guid == tabId }) else { return nil }
            panes.append(tab)
        }
        if group.isPinned {
            // Pinned live: use the record's members in pinned-grid order so
            // the panes match the merged cell, including any pane closed
            // since. Bail when a pane lacks a DB guid (a transient pin/unpin
            // race) so callers don't see a half-formed split.
            guard let dbGuid = panes.first?.guidInLocalDB, !dbGuid.isEmpty,
                  panes.allSatisfy({ $0.guidInLocalDB?.isEmpty == false }),
                  let record = pinnedTabs.first(where: { $0.guidInLocalDB == dbGuid }),
                  let dbGuids = pinnedSplitDBGuids(forPinnedTab: record) else {
                return nil
            }
            let ordered = dbGuids.compactMap { db in
                tabs.first(where: { $0.guidInLocalDB == db })
                    ?? pinnedTabs.first(where: { $0.guidInLocalDB == db })
            }
            guard ordered.count == dbGuids.count else { return nil }
            return SplitMembership(liveGroup: group, pinnedDBGuids: dbGuids, panes: ordered)
        }
        // Non-pinned live: slot order is strip order (Chromium keeps a split
        // contiguous in slot order).
        return SplitMembership(liveGroup: group, pinnedDBGuids: nil, panes: panes)
    }

    private func closedPinnedMembership(pinnedSelf: Tab) -> SplitMembership? {
        guard let dbGuids = pinnedSplitDBGuids(forPinnedTab: pinnedSelf) else {
            return nil
        }
        // Prefer the live tab when a pane happens to be open (URL reflects
        // in-browser navigation); fall back to the pinned record otherwise.
        let panes = dbGuids.compactMap { db in
            tabs.first(where: { $0.guidInLocalDB == db })
                ?? pinnedTabs.first(where: { $0.guidInLocalDB == db })
        }
        guard panes.count == dbGuids.count else { return nil }
        return SplitMembership(liveGroup: nil, pinnedDBGuids: dbGuids, panes: panes)
    }

    /// Resolve the `guidInLocalDB` of every pane of the pinned split that
    /// includes `pinnedTab`. Returns `nil` for solo pinned tabs.
    ///
    /// Mirrors the grouping used by the sidebar
    /// `PinnedTabViewController.buildTabSectionItems` and the tab strip
    /// `pinnedSplitCollapseInfo` so a click on a pinned-split cell drives
    /// the same routing the rendering already expressed. Member sources:
    ///   1. Live `SplitGroup` flagged `isPinned` — covers the common case
    ///      where the panes are currently open Chromium tabs.
    ///   2. Persisted `Tab.splitPaneGuids` — a split of three or four panes,
    ///      including panes closed since it was last opened.
    ///   3. Persisted `Tab.splitPartnerGuid` — a pair, when no live group
    ///      covers it. Survives restarts and covers records waiting to be
    ///      reopened.
    /// The returned ordering follows the tabs' positions in `pinnedTabs`,
    /// matching the sidebar / strip layout.
    func pinnedSplitDBGuids(forPinnedTab pinnedTab: Tab) -> [String]? {
        guard let myDB = pinnedTab.guidInLocalDB, !myDB.isEmpty else { return nil }

        var members: [String] = []
        if let liveTab = tabs.first(where: { $0.guidInLocalDB == myDB }),
           let group = splits.first(where: { $0.isPinned && $0.contains(tabId: liveTab.guid) }) {
            members = group.tabIds.compactMap { tabId in
                tabs.first(where: { $0.guid == tabId })?.guidInLocalDB
            }
        }
        // A half-written list may be missing from this row, so any row that
        // names this one counts.
        let persistedList = pinnedTab.splitPaneGuids.isEmpty
            ? pinnedTabs.first(where: { $0.splitPaneGuids.contains(myDB) })?.splitPaneGuids ?? []
            : pinnedTab.splitPaneGuids
        members.append(contentsOf: persistedList)
        if members.isEmpty {
            if let persisted = pinnedTab.splitPartnerGuid, !persisted.isEmpty {
                members = [myDB, persisted]
            } else if let reverse = pinnedTabs.first(where: { $0.splitPartnerGuid == myDB })?.guidInLocalDB {
                // Bidirectional fallback: a half-persisted pair may carry only
                // the partner's forward link (the reverse write was dropped on
                // quit before flushing). Pair off whichever side points at us
                // so close / move / render all treat the two as one split.
                members = [myDB, reverse]
            }
        }
        let memberSet = Set(members)
        let ordered = pinnedTabs.compactMap { tab -> String? in
            guard let db = tab.guidInLocalDB, memberSet.contains(db) else { return nil }
            return db
        }
        var seen = Set<String>()
        let unique = ordered.filter { seen.insert($0).inserted }
        guard unique.count >= 2, unique.contains(myDB) else { return nil }
        return unique
    }

    /// Unpin a persisted pinned split whose live `SplitGroup` no longer
    /// exists (its panes are closed). Drops the persisted link, removes the
    /// pinned records, and reopens the panes as a fresh non-pinned split —
    /// matching what `toggleSplitPinStatus` does for the active case where
    /// every pane was live.
    @MainActor
    func unpinClosedPinnedSplit(dbGuids: [String], insertionIndex: Int? = nil) {
        let records = dbGuids.compactMap { db in pinnedTabs.first(where: { $0.guidInLocalDB == db }) }
        let urls = records.compactMap(\.url).filter { !$0.isEmpty }
        guard records.count == dbGuids.count, urls.count == dbGuids.count else {
            return
        }
        let layout = pinnedSplitLayout(dbGuids: dbGuids)
        clearPinnedSplit(dbGuids: dbGuids)
        for record in records {
            localStore.removePinnedTab(record, profileId: profileId, spaceId: spaceId)
        }
        openURLsAsSplit(urls, insertionIndex: insertionIndex, layout: layout)
    }

    /// True when one of the tabs in the split is currently the focusing tab.
    /// Used to render the split background as "active group" vs. "passive group".
    func isSplitGroupActive(_ group: SplitGroup) -> Bool {
        guard let focused = focusingTab else { return false }
        return group.contains(tabId: focused.guid)
    }

    /// True when every tab in a freshly-reported split corresponds to a
    /// pinned tab record in `pinnedTabs`. Used at split-creation time to seed
    /// `SplitGroup.isPinned` so restored/recreated pinned splits render as
    /// one cell without waiting on a Mac-side toggle.
    func isSplitMembersAllPinned(tabIds: [Int]) -> Bool {
        let pinnedDBGuids = Set(pinnedTabs.compactMap { $0.guidInLocalDB })
        for tabId in tabIds {
            guard let live = tabs.first(where: { $0.guid == tabId }),
                  let dbGuid = live.guidInLocalDB,
                  pinnedDBGuids.contains(dbGuid) else { return false }
        }
        return true
    }

    /// Flattened tabId → last pane's tabId lookup across all splits in this
    /// window. Consumed by tab-insertion logic so a link opened from a split
    /// tab lands after the whole split instead of between its panes.
    func splitLastTabIdByMemberMap() -> [Int: Int] {
        splits.reduce(into: [:]) { result, group in
            for tabId in group.tabIds {
                result[tabId] = group.lastTabId
            }
        }
    }

    /// Contiguous runs of split panes in `normalTabs`, as (lowest index,
    /// pane count). Only splits whose panes sit at consecutive indices in
    /// slot order count. Consumed by the drag controllers to keep the drop
    /// indicator from landing between two panes.
    func splitRunsInNormalTabs() -> [(lower: Int, count: Int)] {
        splits.compactMap { group in
            var indices: [Int] = []
            for tabId in group.tabIds {
                guard let index = normalTabs.firstIndex(where: { $0.guid == tabId }) else { return nil }
                indices.append(index)
            }
            for (offset, index) in indices.enumerated() where index != indices[0] + offset {
                return nil
            }
            return (indices[0], indices.count)
        }
    }

    /// If `toIndex` would drop a tab strictly between two panes of a split,
    /// return the closest legal index on the side that matches the drag
    /// direction. Split panes are always adjacent in the tab strip, so for a
    /// run at positions (k ..< k + count) the forbidden insertion indices
    /// are k + 1 ... k + count - 1.
    /// Caller is responsible for the early-return when the dragged tab itself
    /// belongs to a split (those moves go through `moveSplit`, not this path).
    ///
    /// Reuses `splitRunsInNormalTabs` as the single source of the adjacency
    /// arithmetic; the tab-strip drag controller's `snapGapOutsideSplit`
    /// consumes the same runs, so the "where do the splits sit" logic lives
    /// in exactly one place on the Swift side.
    func snapDropOutsideSplit(toIndex: Int, fromIndex: Int) -> Int {
        guard let run = splitRunsInNormalTabs().first(where: {
            toIndex > $0.lower && toIndex < $0.lower + $0.count
        }) else {
            return toIndex
        }
        // Snap past the run on whichever side matches the drag direction.
        return fromIndex <= run.lower ? run.lower + run.count : run.lower
    }

    // MARK: - Chromium → Mac handlers

    @MainActor
    func handleSplitCreated(splitId: String,
                            tabIds: [Int],
                            layout: SplitLayout,
                            fractions: [Double]) {
        assert(Thread.isMainThread, "handleSplitCreated must run on the main thread")
        guard tabIds.count >= 2 else {
            AppLogError("[Split] created with \(tabIds.count) panes; ignoring \(splitId)")
            return
        }

        // A split whose panes are all already pinned is itself pinned.
        // Inferring it here (rather than relying on `toggleSplitPinStatus`)
        // means a split that Chromium auto-restores — or one we recreate
        // from a persisted `splitPartnerGuid` pair — picks up the pinned
        // flag without needing a separate Mac-side toggle.
        //
        // The inference reads `pinnedTabs`, which is fed by an async
        // publisher. Callers that pinned a pane synchronously moments before
        // `createSplit` register the splitId in
        // `pendingPinnedSplitMarkByCreateId` so the pinned flag lands here
        // without racing the publisher.
        let forcedPinned = pendingPinnedSplitMarkByCreateId.remove(splitId) != nil
        let pinnedFlag = forcedPinned || isSplitMembersAllPinned(tabIds: tabIds)
        let group = SplitGroup(id: splitId,
                               tabIds: tabIds,
                               layout: layout,
                               fractions: fractions,
                               isPinned: pinnedFlag)
        if let index = splits.firstIndex(where: { $0.id == splitId }) {
            splits[index] = group
        } else {
            splits.append(group)
        }
        // The split a pane was just replaced in, back under its id: its
        // bookmark takes it again and saves the new pane.
        if let swap = pendingBoundSplitPaneSwaps.removeValue(forKey: splitId),
           swap.tabIds.count == tabIds.count {
            for bookmarkGuid in swap.bookmarkGuids
            where bookmarkManager.bookmark(withGuid: bookmarkGuid) != nil {
                splitBookmarkBindings[bookmarkGuid] = splitId
            }
            saveBoundBookmarkPanes(group, previousTabIds: swap.tabIds)
        }
        // After `splits`, so the page container mounts the waiting pane with
        // its split. Checked first: a restore replays every split here, and
        // each write would publish.
        let members = Set(tabIds)
        if !tabsAwaitingSplit.isDisjoint(with: members) {
            tabsAwaitingSplit.subtract(members)
        }
        // The split holds them now: its bookmark binding hides them from
        // here on, and without one they are listed below.
        let wereOpeningBehindBookmark = !splitPaneIdsOpeningBehindBookmark.isDisjoint(with: members)
        if wereOpeningBehindBookmark {
            splitPaneIdsOpeningBehindBookmark.subtract(members)
        }
        if let preview = pendingSplitPreview, preview.isCommitted,
           members.contains(preview.partnerTabId) {
            pendingSplitPreview = nil
        }

        // `consumePendingSplitPartner` already called `placeTabAdjacent`,
        // but a Chromium `tabIndicesUpdated` echo for the just-created
        // pane can land between that placement and this handler and
        // re-sequence `normalTabOrder` back to the pre-placement order via
        // `reorderTabs`. Re-assert adjacency now that the SplitGroup is in
        // `splits`, and republish so the sidebar / tab strip re-render.
        if enforceSplitAdjacency() {
            updateNormalTabs()
        }

        // Closed-split drop relocation: a split opened from a closed bookmark
        // or unopened pinned pair was materialized at the strip's end (its
        // panes are bridge-created tabs with no insert hint). Now that the
        // SplitGroup exists, move the split as a unit to the drop index the
        // user released on. Deferred: running synchronously can land
        // mid-Chromium-mutation and trip `MoveSplitTo`'s reentrancy guard.
        // Re-resolve the group inside the Task since it may have been torn
        // down.
        if let targetIndex = pendingSplitMoveToNormalIndexByCreateId.removeValue(forKey: splitId) {
            Task { @MainActor [weak self] in
                guard let self, let liveGroup = self.splitGroup(forId: splitId) else { return }
                self.moveSplitOrderLocally(group: liveGroup, to: targetIndex)
            }
        }

        // `consumePendingSplitPartner` registers the bookmark→split binding
        // immediately after `createSplit` returns, but at that point this
        // group hasn't been appended to `splits` yet — the bridge call is
        // synchronous from Swift but Chromium echoes the split back here
        // asynchronously. Sync now that the group exists so the bookmark
        // cell picks up opened/active state, then refilter so the panes
        // hide behind the bookmark cell without waiting for another tab event.
        let boundBookmarkGuids = splitBookmarkBindings
            .filter { $0.value == splitId }
            .map { $0.key }
        if !boundBookmarkGuids.isEmpty {
            for bookmarkGuid in boundBookmarkGuids {
                syncSplitBookmarkOpenedState(bookmarkGuid: bookmarkGuid)
            }
            updateNormalTabs()
        } else if wereOpeningBehindBookmark {
            // The bookmark let go of the split while it was opening (deleted,
            // or the layout stopped attaching bookmarks): list its panes.
            updateNormalTabs()
        }

        reconcileSplitChatBinding(group)
        syncSplitAIChatCollapsed(group)
        notifyTravelBackSceneChanged(tabIds: group.tabIds)
        openNextPendingPane(splitId: splitId)
    }

    /// A reopening closed split of three or four panes: opens the next URL as
    /// a new pane. Runs again when that pane lands, until none are left.
    /// Deferred so the Chromium event being handled finishes unwinding first.
    private func openNextPendingPane(splitId: String) {
        guard var urls = pendingSplitAdditionalPaneURLsById[splitId], !urls.isEmpty else { return }
        let url = urls.removeFirst()
        if urls.isEmpty {
            pendingSplitAdditionalPaneURLsById.removeValue(forKey: splitId)
        } else {
            pendingSplitAdditionalPaneURLsById[splitId] = urls
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let group = self.splitGroup(forId: splitId) else { return }
            self.openNewTabJoiningSplit(splitId: splitId, slot: group.paneCount, navigateURL: url)
        }
    }

    /// Sync every pane of a freshly-created split to one AI Chat collapse
    /// state, so switching the active pane does not toggle the sidebar
    /// between collapsed and expanded.
    ///
    /// Bias toward expanded: if any pane has chat open, keep all open.
    /// A freshly-opened pane ("open in split view" / drag-to-split)
    /// lands on NTP with `aiChatCollapsed = true` (the default) and is
    /// often the focused pane when this runs, so picking the focused pane's
    /// state would yank the other panes' open chat shut.
    @MainActor
    func syncSplitAIChatCollapsed(_ group: SplitGroup) {
        let panes = group.tabIds.compactMap { id in tabs.first(where: { $0.guid == id }) }
        guard panes.count == group.paneCount else { return }
        let targetCollapsed = panes.allSatisfy { $0.aiChatCollapsed }
        for pane in panes where pane.aiChatCollapsed != targetCollapsed {
            pane.toggleAIChat(targetCollapsed)
        }
    }

    /// Reconcile a freshly-created split so it shares exactly one chat tab.
    /// Principle 1: a pane that already has a chat tab keeps it (resolver handles
    /// it; no action needed here). Principle 2: when several panes have a chat
    /// tab, keep the foreground pane's (else the first pane's) and close the
    /// others (a split owns one chat tab), clearing those panes' undo-close
    /// panel records with them.
    @MainActor
    func reconcileSplitChatBinding(_ group: SplitGroup) {
        let panes = group.tabIds.compactMap { id in tabs.first(where: { $0.guid == id }) }
        guard panes.count == group.paneCount else { return }
        let panesWithChat = panes.filter { aiChatTabs[getTabIdentifier(for: $0)] != nil }
        guard panesWithChat.count >= 2 else { return }
        let keeper = panesWithChat.first { $0.guid == focusingTab?.guid } ?? panesWithChat[0]
        for pane in panesWithChat where pane !== keeper {
            closeAIChatTab(for: getTabIdentifier(for: pane))
            splitPaneLostAIChatPanel(pane)
        }
    }

    @MainActor
    func handleSplitVisualsChanged(splitId: String, layout: SplitLayout, fractions: [Double]) {
        guard let index = splits.firstIndex(where: { $0.id == splitId }) else { return }
        splits[index].layout = layout
        splits[index].fractions = SplitGroup.normalizedFractions(
            fractions, paneCount: splits[index].paneCount)
        notifyTravelBackSceneChanged(tabIds: splits[index].tabIds)
        persistRepresentedSplitLayout(splitId: splitId, layout: layout)
    }

    /// Remembers the split `departed` panes just left, for a removal of a
    /// focused pane that follows in the same burst of Chromium events (see
    /// `splitPaneTabIdsJustLeft`). Dropped once that burst has been handled,
    /// so a pane dragged out of the split and closed later is a plain tab.
    @MainActor
    private func noteSplitPanesLeft(_ departed: [Int], previousTabIds: [Int]) {
        let leaving = departed.filter { tabId in tabs.contains { $0.guid == tabId } }
        guard !leaving.isEmpty else { return }
        for tabId in leaving {
            splitPaneTabIdsJustLeft[tabId] = previousTabIds
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for tabId in leaving where self.splitPaneTabIdsJustLeft[tabId] == previousTabIds {
                self.splitPaneTabIdsJustLeft.removeValue(forKey: tabId)
            }
        }
    }

    /// The split's panes changed: a reorder, or a pane joined or left a
    /// split that stays up. `tabIds` is the full new membership in slot
    /// order.
    @MainActor
    func handleSplitContentsChanged(splitId: String, tabIds: [Int]) {
        guard let index = splits.firstIndex(where: { $0.id == splitId }), tabIds.count >= 2 else { return }
        let previous = splits[index]
        let departed = previous.tabIds.filter { !tabIds.contains($0) }
        let joined = tabIds.filter { !previous.tabIds.contains($0) }
        splits[index].tabIds = tabIds
        if splits[index].fractions.count != tabIds.count {
            // Chromium's visuals echo lands right after this; until it does,
            // keep one share per pane so the host lays out every pane.
            splits[index].fractions = SplitGroup.equalFractions(paneCount: tabIds.count)
        }
        if !departed.isEmpty || !joined.isEmpty {
            // A pinned split keeps its record when a pane closes: the merged
            // cell still shows that pane and reopens it on the next click.
            for tabId in departed {
                SidecarAIOutputStateStore.shared.tabDidLeaveSplit(tabId, in: self)
            }
            noteSplitPanesLeft(departed, previousTabIds: previous.tabIds)
            tabsAwaitingSplit.subtract(joined)
            splitPaneIdsOpeningBehindBookmark.subtract(joined)
            reconcileSplitChatBinding(splits[index])
            syncSplitAIChatCollapsed(splits[index])
            // A pane joining a bound split is focused before it lands here
            // (the 3rd/4th pane of a split bookmark), so the focus change
            // computed the bookmark inactive against the old pane set and
            // focus does not move again. Recompute against the fresh panes.
            for (bookmarkGuid, boundSplitId) in splitBookmarkBindings where boundSplitId == splitId {
                syncSplitBookmarkOpenedState(bookmarkGuid: bookmarkGuid)
            }
        }
        notifyTravelBackSceneChanged(tabIds: Array(Set(previous.tabIds + tabIds)))
        if !joined.isEmpty {
            openNextPendingPane(splitId: splitId)
        }
        // A reorder or a replaced pane changes what the split's bookmark or
        // pinned record saves. A pane that only leaves is the split, window
        // or app closing, and a pane that only joins is the saved split
        // still opening: neither changes the entry.
        let isReorder = departed.isEmpty && joined.isEmpty && previous.tabIds != tabIds
        let isReplace = !departed.isEmpty && departed.count == joined.count
        if isReorder || isReplace {
            saveRepresentedSplitPanes(splits[index], previousTabIds: previous.tabIds)
        }
        // The accompanying `TabMoved` event lands first via `reorderTabs` →
        // `updateNormalTabs` → `enforceSplitAdjacency`, which runs against
        // the stale order on this SplitGroup and undoes the strip reorder
        // Chromium just performed. Re-run `updateNormalTabs` now that the
        // group's panes are fresh so `enforceSplitAdjacency` re-applies
        // adjacency in the *new* order. Also covers the bookmark-bound
        // filter that previously gated this call (`splitBookmarkBindings`
        // filtering keys off the panes).
        updateNormalTabs()
    }

    /// Right-click link → "Open link in split view" arrived from Chromium.
    /// The source tab is `partnerTabId`; the linked URL becomes a new pane on
    /// its right. Defers to `openNewTabAsSplit` so the new pane goes
    /// through the standard pendingSplitPartner marker dance and avoids the
    /// blank-pane bounce. Normalizes the partner first — mirrors the
    /// drag-onto-page and bookmark "Open as Split" flows so a pinned or
    /// bookmark-bound source tab doesn't drag its binding into the split.
    /// A source tab already in a split with room gets the link as a new
    /// pane right after it; when the pane can't be added (a full split, or
    /// a pinned split that can't be demoted yet) the link opens in a new tab.
    @MainActor
    func handleOpenLinkAsSplitPartner(partnerTabId: Int, url: String) {
        // A link inside a peek or reader overlay: that page is no strip tab
        // yet — it becomes one, paired with the link.
        if openOverlaySurfaceAsSplit(surfaceTabId: partnerTabId, partnerURL: url) {
            return
        }
        if let group = splitGroup(forTabId: partnerTabId) {
            if let slot = group.slot(of: partnerTabId),
               openNewTabIntoSplit(splitId: group.id, slot: slot + 1, navigateURL: url) {
                return
            }
            AppLogInfo("[Split] openLinkAsSplitPartner: split \(group.id) can't take a pane " +
                       "(panes=\(group.paneCount)), opening link in a new tab")
            createTab(url)
            return
        }
        makeTabNormalOpened(tabId: partnerTabId)
        openNewTabAsSplit(partnerTabId: partnerTabId,
                          newTabSlot: .right,
                          partnerNavigateURL: url)
    }

    @MainActor
    func handleSplitRemoved(splitId: String) {
        let removedSplit = splits.first { $0.id == splitId }
        // A pinned split's underlying Chromium split only dissolves on close
        // (its panes can't be "Remove from Split"-ed). Capture the partner
        // linkage from the still-present live group before dropping it, so the
        // two pinned records survive as one reopenable merged cell instead of
        // splintering into two separate pinned tabs.
        reconcilePinnedSplitPartners()
        if let removedSplit {
            SidecarAIOutputStateStore.shared.splitDidDissolve(removedSplit, in: self)
        }
        splits.removeAll { $0.id == splitId }
        if let removedSplit {
            notifyTravelBackSceneChanged(tabIds: removedSplit.tabIds)
        }
        // Drop any split-bookmark bindings that pointed at this split so the
        // bookmark cell stops claiming "opened" and a fresh click re-opens
        // the split. Capture all keys, clear them in a single pass, then
        // emit the per-bookmark sync — otherwise the sidebar relayout
        // triggered by `syncSplitBookmarkOpenedState` observes a partial
        // state where one binding has been cleared and the rest still
        // claim the split is open.
        pendingSplitAdditionalPaneURLsById.removeValue(forKey: splitId)
        let clearedBookmarkGuids = splitBookmarkBindings
            .filter { $0.value == splitId }
            .map { $0.key }
        for guid in clearedBookmarkGuids {
            splitBookmarkBindings.removeValue(forKey: guid)
        }
        for guid in clearedBookmarkGuids {
            syncSplitBookmarkOpenedState(bookmarkGuid: guid)
        }
        // Unsplit leaves the panes alive as standalone tabs — they were
        // hidden from the sidebar list while bound, so refilter now that
        // the binding is gone so they reappear as normal tab rows.
        if !clearedBookmarkGuids.isEmpty {
            updateNormalTabs()
        }
    }

    // MARK: - Mac → Chromium commands

    /// Creates a split from `tabIds` in that pane order (two to four tabs in
    /// no split). Chromium arranges the tabs next to each other in that order
    /// and reports the split back through `handleSplitCreated`. Returns the
    /// new split ID on success.
    ///
    /// Chromium pivots the split on whichever of the tabs is already active,
    /// so the active tab never bounces HIDDEN → VISIBLE (which
    /// `RenderWidgetHostViewCocoa` does not always cleanly resume from — the
    /// previously-focused tab's pane then renders blank).
    @discardableResult
    func createSplit(tabIds: [Int], layout: SplitLayout) -> String? {
        guard tabIds.count >= 2, tabIds.count <= SplitGroup.maxPaneCount,
              Set(tabIds).count == tabIds.count else { return nil }
        return ChromiumLauncher.sharedInstance().bridge?.createSplit(
            withTabIds: tabIds.map { NSNumber(value: Int64($0)) },
            layout: layout.rawValue,
            windowId: windowId.int64Value)
    }

    /// Pairs two tabs: `leftTabId` takes slot 0 (left / top), `rightTabId`
    /// slot 1.
    @discardableResult
    func createSplit(leftTabId: Int, rightTabId: Int, layout: SplitLayout) -> String? {
        createSplit(tabIds: [leftTabId, rightTabId], layout: layout)
    }

    func removeSplit(_ splitId: String) {
        ChromiumLauncher.sharedInstance().bridge?.removeSplit(splitId, windowId: windowId.int64Value)
    }

    func updateSplitLayout(_ splitId: String, layout: SplitLayout) {
        ChromiumLauncher.sharedInstance().bridge?.updateSplitLayout(splitId,
                                                                    layout: layout.rawValue,
                                                                    windowId: windowId.int64Value)
        persistRepresentedSplitLayout(splitId: splitId, layout: layout)
    }

    /// Close Tab on a pane of a split that a bookmark or a pinned record
    /// stands for closes the whole split: the entry saves every pane, so
    /// the split closes as the one thing the entry shows, and reopens in
    /// full from it.
    /// - Returns: `true` when `tabId` is a pane of such a split and its
    ///   close was handled here; `false` leaves the close to the caller.
    func closeSplitSavedInSidebar(containingTabId tabId: Int) -> Bool {
        guard let group = splitGroup(forTabId: tabId), !splitAllowsPaneRearrangement(group) else { return false }
        noteBookmarkSplitClosing(group)
        closeTabs(group.tabIds.compactMap { id in tabs.first { $0.guid == id } })
        return true
    }

    /// The user is closing the bookmark-bound split `group` whole. Its panes
    /// do not all go at once: a page with an unload handler closes a moment
    /// after the others, and by then the split has dissolved and its
    /// bookmark has let go of it. `updateNormalTabs` keeps the panes out of
    /// the tab list until they are removed: listed, the late one would flash
    /// a row that vanishes. A pane whose page holds the close back (an
    /// unload prompt the user declines) stays open, so whatever is left
    /// after a short wait is listed.
    func noteBookmarkSplitClosing(_ group: SplitGroup) {
        guard splitBookmarkBindings.values.contains(group.id) else { return }
        let tabIds = group.tabIds
        splitPaneIdsClosingBehindBookmark.formUnion(tabIds)
        // Longer than Chromium gives a page's unload handlers to finish.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.listPanesNoLongerClosingBehindBookmark(tabIds)
        }
    }

    /// The panes `tabIds` of a bookmark-bound split that was closing are
    /// staying open: list the ones that were hidden for the close as normal
    /// tabs.
    func listPanesNoLongerClosingBehindBookmark(_ tabIds: [Int]) {
        guard !splitPaneIdsClosingBehindBookmark.isDisjoint(with: tabIds) else { return }
        splitPaneIdsClosingBehindBookmark.subtract(tabIds)
        updateNormalTabs()
    }

    /// Saves the panes of `group` into whatever stands for it in the
    /// sidebar, after its panes were reordered or one was replaced: a bound
    /// split-view bookmark and a pinned split both list their panes in slot
    /// order, so they follow the live split, as a layout change is saved
    /// through `persistRepresentedSplitLayout`.
    /// `previousTabIds` is the membership the saved panes still match.
    private func saveRepresentedSplitPanes(_ group: SplitGroup, previousTabIds: [Int]) {
        saveBoundBookmarkPanes(group, previousTabIds: previousTabIds)
        if group.isPinned {
            savePinnedSplitPanes(group, previousTabIds: previousTabIds)
        }
    }

    private func saveBoundBookmarkPanes(_ group: SplitGroup, previousTabIds: [Int]) {
        let boundBookmarkGuids = splitBookmarkBindings.compactMap { $0.value == group.id ? $0.key : nil }
        guard !boundBookmarkGuids.isEmpty else { return }
        var panes: [BookmarkManager.SplitPaneSource] = []
        for tabId in group.tabIds {
            if let savedIndex = previousTabIds.firstIndex(of: tabId) {
                panes.append(.saved(savedIndex))
            } else if let tab = tabs.first(where: { $0.guid == tabId }),
                      let url = tab.url, !url.isEmpty {
                // A pane that replaced another is saved as the page it shows.
                panes.append(.page(url: url, title: tab.title))
            } else {
                return
            }
        }
        for bookmarkGuid in boundBookmarkGuids {
            bookmarkManager.updateSplitPanes(guid: bookmarkGuid,
                                             to: panes,
                                             savedPaneCount: previousTabIds.count)
            // The first pane may have changed, and the cell shows its favicon.
            syncSplitBookmarkOpenedState(bookmarkGuid: bookmarkGuid)
        }
    }

    /// A pinned split saves one pinned record per pane, in pinned-list
    /// order. Removes the record of a pane that left the split, puts the
    /// records in the split's slot order, and saves the membership again.
    /// Records of panes closed earlier stay, after the live ones. A pane
    /// without a pinned record (a replacement) is not handled: pinned splits
    /// offer no pane swap.
    private func savePinnedSplitPanes(_ group: SplitGroup, previousTabIds: [Int]) {
        func dbGuid(_ tabId: Int) -> String? {
            guard let db = tabs.first(where: { $0.guid == tabId })?.guidInLocalDB, !db.isEmpty,
                  pinnedTabs.contains(where: { $0.guidInLocalDB == db }) else { return nil }
            return db
        }
        let previousDBs = previousTabIds.compactMap(dbGuid)
        let liveDBs = group.tabIds.compactMap(dbGuid)
        guard previousDBs.count == previousTabIds.count,
              liveDBs.count == group.paneCount,
              let firstRecord = pinnedTabs.first(where: { $0.guidInLocalDB == liveDBs[0] }) else { return }
        let removedDBs = previousDBs.filter { !liveDBs.contains($0) }
        let knownDBs = pinnedSplitDBGuids(forPinnedTab: firstRecord) ?? liveDBs
        let closedDBs = knownDBs.filter { !liveDBs.contains($0) && !removedDBs.contains($0) }
        let orderedDBs = liveDBs + closedDBs

        // Captured before any record goes away or moves.
        let members = Set(orderedDBs + removedDBs)
        var anchor: String? = pinnedTabs
            .firstIndex(where: { $0.guidInLocalDB.map(members.contains) ?? false })
            .flatMap { $0 > 0 ? pinnedTabs[$0 - 1].guidInLocalDB : nil }
        let listedDBs = pinnedTabs.compactMap { tab -> String? in
            guard let db = tab.guidInLocalDB, orderedDBs.contains(db) else { return nil }
            return db
        }

        if !removedDBs.isEmpty {
            let removedRecords = removedDBs.compactMap { db in
                pinnedTabs.first(where: { $0.guidInLocalDB == db })
            }
            clearPinnedSplit(dbGuids: removedDBs)
            for record in removedRecords {
                localStore.removePinnedTab(record, profileId: profileId, spaceId: spaceId)
            }
        }
        if listedDBs != orderedDBs {
            for db in orderedDBs {
                guard let record = pinnedTabs.first(where: { $0.guidInLocalDB == db }) else { continue }
                localStore.moveOrCreatePinnedTab(record, after: anchor, profileId: profileId, spaceId: spaceId)
                anchor = db
            }
        }
        if orderedDBs.count >= 2 {
            persistPinnedSplit(dbGuids: orderedDBs, layout: group.layout)
        } else {
            clearPinnedSplit(dbGuids: orderedDBs)
        }
    }

    private func persistRepresentedSplitLayout(splitId: String, layout: SplitLayout) {
        if let group = splits.first(where: { $0.id == splitId }), group.isPinned,
           let record = tabs.first(where: { $0.guid == group.firstTabId })?.guidInLocalDB
               .flatMap({ db in pinnedTabs.first(where: { $0.guidInLocalDB == db }) }),
           let dbGuids = pinnedSplitDBGuids(forPinnedTab: record) {
            updatePinnedSplitLayout(dbGuids: dbGuids, layout: layout)
        }
        for bookmarkGuid in splitBookmarkBindings.compactMap({ $0.value == splitId ? $0.key : nil }) {
            bookmarkManager.updateSplitLayout(guid: bookmarkGuid, layout: layout)
        }
    }

    /// Push the new pane shares to Chromium. Call on drag-end, not on every
    /// drag frame — Chromium is source of truth and will fan a visualsChanged
    /// notification back so the UI converges on whatever value it accepts.
    func updateSplitFractions(_ splitId: String, fractions: [Double]) {
        guard let group = splitGroup(forId: splitId) else { return }
        let normalized = SplitGroup.normalizedFractions(fractions, paneCount: group.paneCount)
        ChromiumLauncher.sharedInstance().bridge?.updateSplitFractions(
            splitId,
            fractions: normalized.map { NSNumber(value: $0) },
            windowId: windowId.int64Value)
    }

    /// A pair's divider position: `ratio` is the first pane's share. No-op
    /// for a wider split, whose panes are sized through
    /// `updateSplitFractions`.
    func updateSplitRatio(_ splitId: String, ratio: Double) {
        // A split created a moment ago has no group here until Chromium echoes
        // it, but Chromium already holds it and takes the ratio.
        if let group = splitGroup(forId: splitId), !group.isPair { return }
        let clamped = max(0.0, min(1.0, ratio))
        ChromiumLauncher.sharedInstance().bridge?.updateSplitFractions(
            splitId,
            fractions: [NSNumber(value: clamped), NSNumber(value: 1 - clamped)],
            windowId: windowId.int64Value)
    }

    /// Reverses the pane order. Refused for a bookmark-bound split, whose
    /// panes do not move.
    func reverseTabsInSplit(_ splitId: String) {
        guard !splitBookmarkBindings.values.contains(splitId) else { return }
        ChromiumLauncher.sharedInstance().bridge?.reverseTabs(inSplit: splitId,
                                                              windowId: windowId.int64Value)
    }

    /// Adds the live tab `tabId` (in no split) to `splitId` as pane `slot`.
    /// Chromium moves the tab next to the split and echoes the membership
    /// through `handleSplitContentsChanged`. Refused for a full split. A
    /// pinned or bookmark-bound split moves to the normal tab list first.
    @discardableResult
    func addTabToSplit(_ splitId: String, tabId: Int, slot: Int) -> Bool {
        guard let group = splitGroup(forId: splitId), group.canAddPane,
              !group.contains(tabId: tabId),
              splitGroup(forTabId: tabId) == nil,
              tabs.contains(where: { $0.guid == tabId }),
              makeSplitNormalOpened(splitId) else { return false }
        // Only normal tabs join a split: a pinned or bookmark-bound pane
        // would drag its binding in.
        makeTabNormalOpened(tabId: tabId)
        tabsAwaitingSplit.insert(tabId)
        ChromiumLauncher.sharedInstance().bridge?.addTab(toSplit: splitId,
                                                         tabId: tabId.int64Value,
                                                         slotIndex: Int32(max(0, min(slot, group.paneCount))),
                                                         windowId: windowId.int64Value)
        let wid = windowId
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.windowId == wid else { return }
            self.tabsAwaitingSplit.remove(tabId)
        }
        return true
    }

    /// Whether the user may move a pane of `group` to another slot or take
    /// one out of it. Not while a pinned tab or a bookmark stands for the
    /// split in the sidebar: the split then shows what that entry saved.
    func splitAllowsPaneRearrangement(_ group: SplitGroup) -> Bool {
        !group.isPinned && !splitBookmarkBindings.values.contains(group.id)
    }

    /// Takes `tabId` out of its split; the other panes stay split. A pair
    /// dissolves instead (Chromium reports `splitRemoved`). Refused for a
    /// pinned or bookmark-bound split.
    func removeTabFromSplit(tabId: Int) {
        guard let group = splitGroup(forTabId: tabId), splitAllowsPaneRearrangement(group) else { return }
        if group.isPair {
            removeSplit(group.id)
            return
        }
        ChromiumLauncher.sharedInstance().bridge?.removeTabFromSplit(withTabId: tabId.int64Value,
                                                                     windowId: windowId.int64Value)
    }

    /// Dissolves the split holding `tabId`: all of its panes stay open as
    /// normal tabs (Chromium reports `splitRemoved`). Refused for a pinned or
    /// bookmark-bound split.
    func dissolveSplit(containingTabId tabId: Int) {
        guard let group = splitGroup(forTabId: tabId), splitAllowsPaneRearrangement(group) else { return }
        removeSplit(group.id)
    }

    /// Moves `tabId` to pane `slot` of its split. Refused for a pinned or
    /// bookmark-bound split.
    func moveTabInSplit(tabId: Int, toSlot slot: Int) {
        guard let group = splitGroup(forTabId: tabId), splitAllowsPaneRearrangement(group),
              slot >= 0, slot < group.paneCount else { return }
        ChromiumLauncher.sharedInstance().bridge?.moveTabInSplit(withTabId: tabId.int64Value,
                                                                 toSlot: Int32(slot),
                                                                 windowId: windowId.int64Value)
    }

    /// Replace one pane of a split with another tab from the strip.
    /// - Parameters:
    ///   - slotIndex: the pane to replace, 0 ..< paneCount.
    ///   - swap: true → the evicted tab moves right next to the split and
    ///     joins its tab group, if any (Chromium's `TabsProxy::UpdateSplitTab`
    ///     stages the incoming tab there before the kSwap); false → close the
    ///     evicted tab.
    func swapTabInSplit(_ splitId: String,
                        slotIndex: Int,
                        withTabId otherTabId: Int,
                        swap: Bool) {
        // Chromium replaces a pane by removing the split and creating it
        // again under the same id. The removal drops a bookmark binding, so
        // note it here for `handleSplitCreated` to restore and to save the
        // new pane into the bookmark.
        let boundBookmarkGuids = splitBookmarkBindings.compactMap { $0.value == splitId ? $0.key : nil }
        if !boundBookmarkGuids.isEmpty, let group = splitGroup(forId: splitId) {
            pendingBoundSplitPaneSwaps[splitId] = (boundBookmarkGuids, group.tabIds)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.pendingBoundSplitPaneSwaps.removeValue(forKey: splitId)
            }
        }
        ChromiumLauncher.sharedInstance().bridge?.swapTab(inSplit: splitId,
                                                          slotIndex: Int32(slotIndex),
                                                          withTabId: otherTabId.int64Value,
                                                          swap: swap,
                                                          windowId: windowId.int64Value)
    }

    func moveSplit(_ splitId: String, toIndex: Int) {
        ChromiumLauncher.sharedInstance().bridge?.moveSplit(splitId,
                                                            to: Int32(toIndex),
                                                            windowId: windowId.int64Value)
    }

    func splitId(forTabId tabId: Int) -> String? {
        ChromiumLauncher.sharedInstance().bridge?.getSplitId(forTabId: tabId.int64Value,
                                                             windowId: windowId.int64Value)
    }

    func listSplitIds() -> [String] {
        ChromiumLauncher.sharedInstance().bridge?.listSplits(inWindow: windowId.int64Value) ?? []
    }

    // MARK: - Pin / Unpin a split

    /// Pin (or unpin) both panes of a split pair as a single action.
    ///
    /// Pinning moves both panes into `pinnedTabs` via the standard per-tab pin
    /// flow but keeps the `SplitGroup` alive and flags it as pinned. The pinned
    /// grid uses that flag to render the pair as one combined cell, so the
    /// split keeps its "one unit" appearance.
    ///
    /// The SplitGroup tracks Chromium tab IDs, which are stable across the
    /// per-tab pin operation — `toggleTabPinStatus` only flips Phi-side state
    /// (`isPinned`, `guidInLocalDB`, the localStore record). Chromium's own
    /// split membership is unaffected.
    ///
    /// Pin every pane of a split at a specific destination in the pinned
    /// grid. Used by the drag-to-pin path so a dropped split lands next to
    /// whatever the user dropped near, rather than always appended at the
    /// end like `toggleSplitPinStatus` does.
    ///
    /// `atIndex` follows the pinned-grid convention (0 = before all pinned
    /// tabs, `pinnedTabs.count` = at the end). The panes are pinned in slot
    /// order so adjacency carries over from the strip into the pinned grid.
    /// After the inserts, the SplitGroup is flagged pinned and the membership
    /// is persisted to match the toggle-pin flow.
    @discardableResult
    @MainActor
    func pinSplitInsertingAtPinnedIndex(_ splitId: String,
                                        atIndex insertionIndex: Int) -> [String]? {
        let clampedIndex = max(0, min(insertionIndex, pinnedTabs.count))
        let anchorGuid: String? = clampedIndex > 0
            ? pinnedTabs[clampedIndex - 1].guidInLocalDB
            : nil
        return pinSplit(splitId, afterPinnedGuid: anchorGuid)
    }

    @discardableResult
    @MainActor
    func pinSplit(_ splitId: String,
                  afterPinnedGuid anchorGuid: String?) -> [String]? {
        guard let groupIndex = splits.firstIndex(where: { $0.id == splitId }) else { return nil }
        let group = splits[groupIndex]
        if group.isPinned { return nil }

        let panes = group.tabIds.compactMap { tabId in tabs.first(where: { $0.guid == tabId }) }
        guard panes.count == group.paneCount else { return nil }
        // Skip if any pane is somehow already pinned — would imply a
        // mismatched state we shouldn't double-write.
        if panes.contains(where: \.isPinned) { return nil }

        splits[groupIndex].isPinned = true
        // Detach the panes from any Chromium tab group before pinning.
        // Phi-side pinning bypasses Chromium's `TabStripModel::SetTabPinned`,
        // so the automatic "pinning detaches from group" never fires. The
        // normal-tab pin path handles this explicitly in `moveNormalTab`,
        // but the split path goes straight to the shared `moveNormalTabToPinned`
        // helper and skips it — without this the panes keep their `groupToken`
        // and re-enter the group on unpin.
        if let bridge = ChromiumLauncher.sharedInstance().bridge {
            let groupedPanes = panes.filter { $0.groupToken != nil }
            if !groupedPanes.isEmpty {
                bridge.removeTabsFromGroup(withWindowId: windowId.int64Value,
                                            tabIds: groupedPanes.map { NSNumber(value: Int64($0.guid)) })
                for pane in groupedPanes {
                    pane.groupToken = nil
                }
            }
        }
        var dbGuids: [String] = []
        var anchor = anchorGuid
        for pane in panes {
            guard let db = moveNormalTabToPinned(pane,
                                                 after: anchor,
                                                 selectAfterMove: pane.isActive) else {
                return nil
            }
            pane.isPinned = true
            dbGuids.append(db)
            anchor = db
        }
        updateNormalTabs()

        persistPinnedSplit(dbGuids: dbGuids, layout: splits[groupIndex].layout)
        return dbGuids
    }

    @MainActor
    func toggleSplitPinStatus(_ splitId: String) {
        guard let index = splits.firstIndex(where: { $0.id == splitId }) else { return }
        if splits[index].isPinned {
            let group = splits[index]
            let primaryGuidInDB = tabs.first(where: { $0.guid == group.firstTabId })?.guidInLocalDB
            let secondaryGuidInDB = tabs.first(where: { $0.guid == group.lastTabId })?.guidInLocalDB
            let activePane = tabs.first { group.contains(tabId: $0.guid) && $0.isActive }
            if let pinnedGuid = primaryGuidInDB ?? secondaryGuidInDB {
                movePinnedTabOut(pinnedGuid: pinnedGuid,
                                 to: normalTabs.count,
                                 selectAfterMove: activePane?.isActive == true)
            } else {
                splits[index].isPinned = false
            }
            return
        }
        // Pinning: delegate to the chained-anchor path so each pane anchors
        // off the previous pane's freshly-issued guidInLocalDB.
        // The per-tab toggle path races the async pinnedTabs publisher and
        // can land a later pane before the first in the DB, which then
        // binds the merged cell's left pane to the wrong tab — closing
        // the cell would only close one pane and strand the other as a
        // pinned placeholder.
        pinSplitInsertingAtPinnedIndex(splitId, atIndex: pinnedTabs.count)
    }

    /// Persist a pinned split's members on its pinned-tab rows and best-effort
    /// patch the in-memory `pinnedTabs` records so the merged pinned cell can
    /// render immediately rather than after the SwiftData publisher
    /// round-trips.
    ///
    /// The in-memory patch silently no-ops when a record hasn't yet appeared
    /// in `pinnedTabs` (e.g. immediately after `moveNormalTabToPinned`, whose
    /// write is async). That is intentional — the publisher delivers the
    /// persisted membership on its next emission and the merged cell renders
    /// correctly from then on. Callers should not rely on the in-memory patch
    /// landing.
    func persistPinnedSplit(dbGuids: [String], layout: SplitLayout) {
        guard dbGuids.count >= 2, dbGuids.allSatisfy({ !$0.isEmpty }) else { return }
        localStore.updatePinnedSplit(guids: dbGuids, layout: layout.rawValue)
        for (index, db) in dbGuids.enumerated() {
            guard let record = pinnedTabs.first(where: { $0.guidInLocalDB == db }) else { continue }
            record.splitPartnerGuid = dbGuids.count == 2 ? dbGuids[1 - index] : nil
            record.splitPaneGuids = dbGuids.count == 2 ? [] : dbGuids
            record.splitLayout = layout
        }
    }

    /// Drop the persisted link from a pinned split's records, in memory and in
    /// the store, ahead of removing or reusing them.
    func clearPinnedSplit(dbGuids: [String]) {
        for db in dbGuids {
            guard let record = pinnedTabs.first(where: { $0.guidInLocalDB == db }) else { continue }
            record.splitPartnerGuid = nil
            record.splitPaneGuids = []
        }
        localStore.clearPinnedSplit(guids: dbGuids)
    }

    func pinnedSplitLayout(dbGuids: [String]) -> SplitLayout {
        dbGuids.lazy.compactMap { db in
            self.pinnedTabs.first(where: { $0.guidInLocalDB == db })?.splitLayout
        }.first ?? .vertical
    }

    func updatePinnedSplitLayout(dbGuids: [String], layout: SplitLayout) {
        guard dbGuids.allSatisfy({ !$0.isEmpty }) else { return }
        localStore.updatePinnedSplitLayout(guids: dbGuids, layout: layout.rawValue)
        for db in dbGuids {
            pinnedTabs.first(where: { $0.guidInLocalDB == db })?.splitLayout = layout
        }
    }

    /// Stamp the persisted membership onto the in-memory pinned records
    /// of every live `isPinned` split, derived from the live `SplitGroup`
    /// rather than waiting on the async store round-trip.
    ///
    /// `pinSplitInsertingAtPinnedIndex` persists the membership to the
    /// store, but the in-memory pinned records only learn it on the next
    /// pinned-tabs publisher emission (`persistPinnedSplit`'s in-memory
    /// patch no-ops because the records don't exist yet at pin time). If the
    /// user closes the split before that echo lands, the live group is
    /// removed (`handleSplitRemoved`) while the pinned records are still
    /// unlinked, and the merged pinned-split cell splinters into separate
    /// pinned tabs. Reconciling from the live group throughout the split's
    /// life — and once more at the instant it is removed — makes the linkage
    /// durable in memory before the group can disappear.
    ///
    /// Safe to over-call: it only writes when a live pane is missing from the
    /// record or the layout differs. A record with more panes than the live
    /// group stays as it is, because closing a pane keeps it in the merged
    /// cell. It never runs for a dissolved pinned split because the only path
    /// that keeps the panes alive while breaking the split
    /// (`unpinSplitPanesIntoNormalList`) clears the group's `isPinned` flag
    /// first. "Remove from Split" / "Reverse Panes" are not offered for
    /// pinned splits.
    func reconcilePinnedSplitPartners() {
        guard !isIncognito else { return }
        let pinnedByDB: [String: Tab] = Dictionary(
            pinnedTabs.compactMap { tab in tab.guidInLocalDB.map { ($0, tab) } },
            uniquingKeysWith: { first, _ in first }
        )
        for group in splits where group.isPinned {
            let liveDBs = group.tabIds.compactMap { tabId in
                tabs.first(where: { $0.guid == tabId })?.guidInLocalDB
            }
            let records = liveDBs.compactMap { pinnedByDB[$0] }
            guard liveDBs.count == group.paneCount,
                  liveDBs.allSatisfy({ !$0.isEmpty }),
                  records.count == liveDBs.count else {
                continue
            }
            let persisted = Set(records.flatMap { record -> [String] in
                guard let db = record.guidInLocalDB else { return [] }
                if !record.splitPaneGuids.isEmpty { return record.splitPaneGuids }
                return record.splitPartnerGuid.map { [db, $0] } ?? [db]
            })
            let isLinked = records.allSatisfy { record in
                guard let db = record.guidInLocalDB else { return false }
                return record.splitPaneGuids.contains(db)
                    || (record.splitPartnerGuid.map { liveDBs.contains($0) } ?? false)
            }
            let dbGuids = pinnedTabs.compactMap { tab -> String? in
                guard let db = tab.guidInLocalDB,
                      persisted.contains(db) || liveDBs.contains(db) else { return nil }
                return db
            }
            if !isLinked || !Set(liveDBs).isSubset(of: persisted) {
                persistPinnedSplit(dbGuids: dbGuids, layout: group.layout)
            } else if records.contains(where: { $0.splitLayout != group.layout }) {
                updatePinnedSplitLayout(dbGuids: dbGuids, layout: group.layout)
            }
        }
    }

    // MARK: - Pinned-split restoration

    /// Open every pane of a persisted pinned split. Used when the user clicks
    /// the merged-cell representation of a pinned split that was restored
    /// from disk: any of the underlying Chromium tabs may be closed, so we
    /// issue `createTab` for whichever panes are missing. Once they reach
    /// `handleNewTabFromChromium`, the pinned-tab auto-bind path calls
    /// `maybeRecreatePersistedPinnedSplit` which then creates the `SplitGroup`.
    ///
    /// - Parameter focusGuid: the pane that becomes the focused tab once every
    ///   pane is open (the one the user clicked); nil focuses the first pane.
    @MainActor
    func openPinnedSplit(dbGuids: [String], focusGuid: String?) {
        let records = dbGuids.compactMap { db in pinnedTabs.first(where: { $0.guidInLocalDB == db }) }
        guard records.count == dbGuids.count, dbGuids.count >= 2 else { return }
        let focusDB = focusGuid.flatMap { dbGuids.contains($0) ? $0 : nil } ?? dbGuids[0]
        let closed = records.filter { record in
            tabs.first(where: { $0.guidInLocalDB == record.guidInLocalDB })?.webContentWrapper == nil
        }

        // Fast path: every pane already live. If a `SplitGroup` already covers
        // them (Chromium auto-restored it, or the user re-clicked the cell
        // while they were still open) just activate the preferred pane.
        if closed.isEmpty {
            tabs.first(where: { $0.guidInLocalDB == focusDB })?.webContentWrapper?.setAsActiveTab()
            pendingPinnedSplitRecreateGuids.formUnion(dbGuids)
            tryRecreatePendingPinnedSplit(dbGuids: dbGuids)
            return
        }

        // Mark every pane as awaiting recreation so the next-arriving tabs
        // know to trigger `createSplit`. Without this gate, Chromium's own
        // session-restore path could also reach `handleNewTabFromChromium`
        // for these guids and race against our `createSplit`.
        pendingPinnedSplitRecreateGuids.formUnion(dbGuids)

        for record in closed {
            createTab(record.url ?? "",
                      customGuid: record.guidInLocalDB,
                      focusAfterCreate: record.guidInLocalDB == focusDB)
        }
    }

    /// When a pinned tab just bound to a live Chromium tab, check whether the
    /// rest of its split is also live, the split was explicitly requested via
    /// `openPinnedSplit`, and no `SplitGroup` covers it yet. If so, schedule
    /// a `createSplit` on the next run-loop tick so it does not re-enter the
    /// new-tab event flow.
    func maybeRecreatePersistedPinnedSplit(forJustOpenedPinnedTab pinnedTab: Tab) {
        guard let dbGuids = pinnedSplitDBGuids(forPinnedTab: pinnedTab),
              dbGuids.allSatisfy({ pendingPinnedSplitRecreateGuids.contains($0) }) else {
            return
        }
        tryRecreatePendingPinnedSplit(dbGuids: dbGuids)
    }

    /// Validate every pane is live, then schedule a deferred `createSplit`, or
    /// add the reopened panes to the live group that survived a pane closing.
    /// Pending markers are cleared up front so the deferred task is the only
    /// attempt; if Chromium rejects the split we don't keep retrying.
    private func tryRecreatePendingPinnedSplit(dbGuids: [String]) {
        let panes = dbGuids.compactMap { db in tabs.first(where: { $0.guidInLocalDB == db }) }
        guard panes.count == dbGuids.count,
              panes.allSatisfy({ $0.webContentWrapper != nil }) else {
            return
        }
        let liveGroups = panes.compactMap { splitGroup(forTabId: $0.guid) }
        if liveGroups.count == panes.count {
            pendingPinnedSplitRecreateGuids.subtract(dbGuids)
            return
        }

        // A previous click already queued the async `createSplit` for this
        // split. Without this guard, a rapid double click on the merged cell
        // would queue a second async block and `createSplit` would fire twice
        // (the first one likely succeeds, the second's guard at the head of
        // the block catches it, but the two requests racing against Chromium
        // is brittle — earlier rejection avoids the race entirely).
        if dbGuids.contains(where: { pinnedSplitRecreateInFlight.contains($0) }) {
            return
        }

        pendingPinnedSplitRecreateGuids.subtract(dbGuids)
        pinnedSplitRecreateInFlight.formUnion(dbGuids)
        let tabIds = panes.map(\.guid)
        let layout = pinnedSplitLayout(dbGuids: dbGuids)
        // Defer to the next runloop so the surrounding new-tab event finishes
        // unwinding before we reach back into Chromium. Calling `createSplit`
        // synchronously inside `handleNewTabFromChromium` can crash because
        // Chromium is still finalizing tab-strip state for the arriving tab.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.pinnedSplitRecreateInFlight.subtract(dbGuids) }
            // Bail if a pane has been unbound from its pinned DB guid by the
            // time this deferred block runs — e.g. the user dragged the pinned
            // split out to the normal tab list or to a bookmark before the
            // recreate fired. Without this guard the deferred fires
            // `createSplit` on now-unbound tabs and either duplicates an
            // explicit `createSplit` already issued by the drag-out path
            // (racing against Chromium's echo of the first one) or attaches
            // a stray pinned-style split to tabs the user just freed.
            for (tabId, db) in zip(tabIds, dbGuids) {
                guard let live = self.tabs.first(where: { $0.guid == tabId }),
                      live.webContentWrapper != nil,
                      live.guidInLocalDB == db else {
                    return
                }
            }
            if let group = tabIds.lazy.compactMap({ self.splitGroup(forTabId: $0) }).first {
                // Slots follow the grid order the panes were listed in.
                for (slot, tabId) in tabIds.enumerated() where !group.contains(tabId: tabId) {
                    ChromiumLauncher.sharedInstance().bridge?.addTab(toSplit: group.id,
                                                                     tabId: tabId.int64Value,
                                                                     slotIndex: Int32(slot),
                                                                     windowId: self.windowId.int64Value)
                }
                return
            }
            self.createSplit(tabIds: tabIds, layout: layout)
        }
    }

    // MARK: - Open-new-tab-into-split

    /// When the live tab `tabId` is currently pinned, unpins it into the
    /// normal list and writes a fresh unopened pinned record at the
    /// original pinned slot pointing at the same URL. No-op for non-pinned
    /// tabs. Shared by every split-formation entry point — right-click
    /// "Open as Split" on a pinned tab, drag-to-split from the pinned
    /// grid, and drag-onto a pinned focused tab — so the resulting split
    /// is always a normal-list split and the pinned slot keeps its visual
    /// continuity via the placeholder.
    func demotePinnedTabLeavingPlaceholder(forTabId tabId: Int) {
        guard let liveTab = tabs.first(where: { $0.guid == tabId }),
              let pinnedGuid = liveTab.guidInLocalDB, !pinnedGuid.isEmpty,
              let pinnedRecord = pinnedTabs.first(where: { $0.guidInLocalDB == pinnedGuid }),
              let pinnedIndex = pinnedTabs.firstIndex(where: { $0.guidInLocalDB == pinnedGuid })
        else { return }
        // Anchor for the placeholder: the pinned guid that currently sits
        // immediately before the partner. Captured BEFORE the unpin removes
        // the partner from `pinnedTabs` and shifts indices.
        let afterGuid: String? = pinnedIndex > 0
            ? pinnedTabs[pinnedIndex - 1].guidInLocalDB
            : nil
        // Prefer `pinnedUrl` — that's the canonical URL the user committed
        // through the "Edit Pinned Tab" form (`applyPinnedTabEdit` writes
        // it). The live tab's `url` reflects whatever the user has since
        // navigated to inside the pane and would make the placeholder
        // point at the wrong page after a single in-tab click.
        let placeholderURL = pinnedRecord.pinnedUrl ?? pinnedRecord.url ?? liveTab.url ?? ""
        let placeholderTitle = pinnedRecord.storedTitle
            ?? (pinnedRecord.title.isEmpty ? liveTab.title : pinnedRecord.title)
        guard !placeholderURL.isEmpty else { return }
        // Move the live tab to the top of the normal list. The exact landing
        // slot doesn't matter much — the split adjacency pass in
        // `consumePendingSplitPartner` (`placeTabAdjacent`) will reposition
        // the panes together once the new tab arrives.
        movePinnedTabOut(pinnedGuid: pinnedGuid, to: 0)
        // Recreate an unopened pinned record at the original slot. A bare
        // Tab carrying just url+title is enough — `moveOrCreatePinnedTab`
        // mints a fresh DB guid and persists it as a closed pinned entry.
        let placeholder = Tab(url: placeholderURL,
                              isActive: false,
                              index: pinnedIndex,
                              title: placeholderTitle)
        localStore.moveOrCreatePinnedTab(placeholder,
                                         after: afterGuid,
                                         profileId: profileId,
                                         spaceId: spaceId,
                                         newGuid: UUID().uuidString)
    }

    /// Normalizes `tabId` into the plain opened tab list: unpins a pinned
    /// tab (leaving a placeholder via `demotePinnedTabLeavingPlaceholder`)
    /// and clears any bookmark binding. No-op when the tab is already a
    /// plain entry. Callers must not invoke this on a tab that is part of
    /// a live split — the participating split-formation entry points reject
    /// those cases before calling here.
    func makeTabNormalOpened(tabId: Int) {
        guard let tab = tabs.first(where: { $0.guid == tabId }) else { return }
        // Pinned membership is detected via the pinned-records lookup, NOT
        // `tab.isPinned`. The live flag isn't reliably set on the
        // auto-reattach path that runs when a pinned slot's tab opens at
        // launch / session-restore — `toggleTabPinStatus` is the only flip.
        // The DB-guid presence in `pinnedTabs` is the canonical signal.
        if let dbGuid = tab.guidInLocalDB, !dbGuid.isEmpty,
           pinnedTabs.contains(where: { $0.guidInLocalDB == dbGuid }) {
            demotePinnedTabLeavingPlaceholder(forTabId: tabId)
            return
        }
        if let dbGuid = tab.guidInLocalDB, !dbGuid.isEmpty {
            // Bookmark-bound (non-pinned). Drop both the Swift mirror and
            // the Chromium customGuid marker so
            // `CrossDomainNewTabNavigationThrottle` stops treating the tab
            // as bookmark-bound, then re-sync bookmark state so the
            // bookmark cell stops rendering as opened.
            setBinding(nil, for: tab)
            syncAllBookmarksOpenedState()
        }
    }

    /// Normalizes a live split into the normal tab list before it takes a new
    /// pane, the split counterpart of `makeTabNormalOpened`: a pinned split
    /// leaves a closed pinned split at its slot, and a bookmark-bound split
    /// leaves its bookmark closed. No-op for a split already in the list.
    /// - Returns: `false` when the split is still pinned afterwards, in which
    ///   case the caller must not add the pane.
    @discardableResult
    func makeSplitNormalOpened(_ splitId: String) -> Bool {
        guard let group = splitGroup(forId: splitId) else { return false }
        if group.isPinned {
            demotePinnedSplitLeavingPlaceholder(group)
            guard splitGroup(forId: splitId)?.isPinned == false else { return false }
        }
        let boundBookmarkGuids = splitBookmarkBindings
            .filter { $0.value == splitId }
            .map { $0.key }
        guard !boundBookmarkGuids.isEmpty else { return true }
        // Clear every binding before any sync, so no refilter sees one
        // binding gone and another still claiming the split.
        for bookmarkGuid in boundBookmarkGuids {
            splitBookmarkBindings.removeValue(forKey: bookmarkGuid)
        }
        for bookmarkGuid in boundBookmarkGuids {
            syncSplitBookmarkOpenedState(bookmarkGuid: bookmarkGuid)
        }
        // Local inserts, then one split move: a per-pane Chromium move would
        // dissolve the split.
        for (offset, tabId) in group.tabIds.enumerated() {
            insertIntoNormalTabOrder(tabGuid: tabId, at: offset, syncChromiumOrder: false)
        }
        moveSplit(splitId, toIndex: 0)
        return true
    }

    /// `demotePinnedTabLeavingPlaceholder` for a whole split: the live panes
    /// move to the top of the normal list as a split, and a closed pinned
    /// split with the same panes takes the original slot. Panes closed since
    /// the split opened stay in the placeholder.
    private func demotePinnedSplitLeavingPlaceholder(_ group: SplitGroup) {
        let livePanes = group.tabIds.compactMap { tabId in tabs.first(where: { $0.guid == tabId }) }
        let liveDBGuids = livePanes.compactMap(\.guidInLocalDB)
        guard livePanes.count == group.paneCount, liveDBGuids.count == group.paneCount,
              let firstRecord = pinnedTabs.first(where: { $0.guidInLocalDB == liveDBGuids[0] }),
              let dbGuids = pinnedSplitDBGuids(forPinnedTab: firstRecord),
              Set(liveDBGuids).isSubset(of: dbGuids),
              let firstIndex = pinnedTabs.firstIndex(where: { $0.guidInLocalDB == dbGuids[0] }) else { return }
        let records = dbGuids.compactMap { db in pinnedTabs.first(where: { $0.guidInLocalDB == db }) }
        // The committed pinned URL, not wherever the pane has navigated since.
        let placeholders = records.map { record -> (url: String, title: String) in
            let live = livePanes.first(where: { $0.guidInLocalDB == record.guidInLocalDB })
            return (url: record.pinnedUrl ?? record.url ?? live?.url ?? "",
                    title: record.storedTitle ?? (record.title.isEmpty ? live?.title ?? "" : record.title))
        }
        guard records.count == dbGuids.count, placeholders.allSatisfy({ !$0.url.isEmpty }) else { return }
        // Captured before the unpin removes these records and shifts indices.
        var anchor: String? = firstIndex > 0 ? pinnedTabs[firstIndex - 1].guidInLocalDB : nil

        unpinSplitPanesIntoNormalList(dbGuids: liveDBGuids, insertIndex: 0)
        let closedRecords = records.filter { record in
            !liveDBGuids.contains(record.guidInLocalDB ?? "")
        }
        clearPinnedSplit(dbGuids: closedRecords.compactMap(\.guidInLocalDB))
        for record in closedRecords {
            localStore.removePinnedTab(record, profileId: profileId, spaceId: spaceId)
        }

        var placeholderGuids: [String] = []
        for placeholder in placeholders {
            let newGuid = UUID().uuidString
            let tab = Tab(url: placeholder.url, isActive: false, index: firstIndex, title: placeholder.title)
            localStore.moveOrCreatePinnedTab(tab,
                                             after: anchor,
                                             profileId: profileId,
                                             spaceId: spaceId,
                                             newGuid: newGuid)
            placeholderGuids.append(newGuid)
            anchor = newGuid
        }
        persistPinnedSplit(dbGuids: placeholderGuids, layout: group.layout)
    }

    /// Forms a split between a bookmark and `partnerTabId`. If the
    /// bookmark currently has an attached live tab that is distinct from
    /// the partner and not already in a split, detaches that tab from the
    /// bookmark binding and uses it as the new pane directly — the user
    /// keeps the open page instead of getting a fresh duplicate. Otherwise
    /// opens a new tab on the bookmark URL via `openNewTabAsSplit`. Shared
    /// by the drag-onto-page flow, the bookmark "Open as Split" menu, and
    /// any future entry point so all three behave identically.
    /// - Returns: `true` when a split command was dispatched, `false` when
    ///   the bookmark or partner is no longer eligible. The caller may fall
    ///   back to other entry points.
    @discardableResult
    func formSplitFromBookmark(bookmarkGuid: String,
                               partnerTabId: Int,
                               newTabSlot: SplitSlot,
                               layout: SplitLayout = .vertical) -> Bool {
        guard let bookmark = bookmarkManager.bookmark(withGuid: bookmarkGuid),
              !bookmark.isFolder,
              let url = bookmark.url, !url.isEmpty,
              splitGroup(forTabId: partnerTabId) == nil else { return false }
        // Resolve the bookmark's attached live tab BEFORE the partner
        // normalization below — `makeTabNormalOpened(partnerTabId)` clears
        // the partner tab's `guidInLocalDB`, so if the attached
        // representation IS the partner pane the post-detach lookup would
        // miss and we'd fall through to opening a duplicate URL tab.
        let attachedLiveTab = tabs.first(where: { $0.guidInLocalDB == bookmarkGuid })
        // Normalize the partner (the split's other pane). Otherwise the
        // resulting split would inherit pinned-ness or a bookmark binding
        // unrelated to the new split — contrary to user intent.
        makeTabNormalOpened(tabId: partnerTabId)
        // Attached-and-distinct: detach the bookmark's live tab into the
        // normal tab list, then pair it directly with the partner. The
        // bookmark cell stops rendering as opened once
        // `syncAllBookmarksOpenedState` runs inside `makeTabNormalOpened`.
        if let attachedLiveTab,
           attachedLiveTab.guid != partnerTabId,
           splitGroup(forTabId: attachedLiveTab.guid) == nil {
            makeTabNormalOpened(tabId: attachedLiveTab.guid)
            let splitId: String?
            switch newTabSlot {
            case .left:
                splitId = createSplit(leftTabId: attachedLiveTab.guid,
                                      rightTabId: partnerTabId,
                                      layout: layout)
            case .right:
                splitId = createSplit(leftTabId: partnerTabId,
                                      rightTabId: attachedLiveTab.guid,
                                      layout: layout)
            }
            return splitId != nil
        }
        // Attached-and-IS-partner: the partner tab was the bookmark's live
        // representation and is now detached above. Opening another tab on
        // the same URL would just duplicate the partner pane's content, so
        // use a blank NTP partner instead. The detached (formerly
        // attached) partner keeps the dropped slot; the new NTP takes the
        // opposite side.
        if attachedLiveTab?.guid == partnerTabId {
            let oppositeSlot: SplitSlot = (newTabSlot == .left) ? .right : .left
            return openNewTabAsSplit(partnerTabId: partnerTabId,
                                     newTabSlot: oppositeSlot,
                                     layout: layout)
        }
        // Bookmark has no live representation: materialize a fresh unbound
        // tab on the bookmark URL as the new pane.
        return openNewTabAsSplit(partnerTabId: partnerTabId,
                                 newTabSlot: newTabSlot,
                                 partnerNavigateURL: URLProcessor.processUserInput(url),
                                 layout: layout)
    }

    /// "Split with New Tab" applies to a focused tab in no split, and to a
    /// pane of a split with room for another pane.
    var canSplitFocusedTabWithNewTab: Bool {
        guard !isKioskWindow, !isInPlaceholderMode, groupOverviewState == nil,
              pendingSplitPreview == nil, let tab = focusingTab else { return false }
        guard let group = splitGroup(forTabId: tab.guid) else { return true }
        return group.canAddPane
    }

    /// Tab menu / shortcut "Split with New Tab": keeps the focused tab on the
    /// left. Under the New Tab Page behavior the right pane is a new-tab page;
    /// under Omnibox it is previewed blank and the omnibox's submission
    /// becomes the pane (`commitSplitPreview`). A focused pane of a split
    /// gets a new-tab page as the pane right after it (no omnibox preview:
    /// the preview host shows a pair).
    @discardableResult
    func splitFocusedTabWithNewTab() -> Bool {
        guard canSplitFocusedTabWithNewTab, let tab = focusingTab else { return false }
        if let group = splitGroup(forTabId: tab.guid), let slot = group.slot(of: tab.guid) {
            return openNewTabIntoSplit(splitId: group.id, slot: slot + 1, navigateURL: nil)
        }
        if PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.loadValue() {
            makeTabNormalOpened(tabId: tab.guid)
            return openNewTabAsSplit(partnerTabId: tab.guid)
        }
        guard let windowController else { return false }
        pendingSplitPreview = PendingSplitPreview(partnerTabId: tab.guid)
        // Next turn, after the page container has mounted the preview.
        DispatchQueue.main.async { [weak self, weak windowController] in
            guard self?.pendingSplitPreview?.isCommitted == false else { return }
            windowController?.presentSplitPreviewOmniBox()
        }
        return true
    }

    /// Opens the omnibox submission `url` as the previewed pane. Returns false
    /// when no preview is waiting for one.
    func commitSplitPreview(url: String) -> Bool {
        guard var preview = pendingSplitPreview, !preview.isCommitted else { return false }
        preview.isCommitted = true
        pendingSplitPreview = preview
        // Keep the bookmark binding while previewing; release it only on submission.
        makeTabNormalOpened(tabId: preview.partnerTabId)
        guard openNewTabAsSplit(partnerTabId: preview.partnerTabId,
                                partnerNavigateURL: url) else {
            pendingSplitPreview = nil
            return false
        }
        expireCommittedSplitPreview(preview)
        return true
    }

    /// Hold-⌘ on an open-tab suggestion: pairs that tab as the previewed pane,
    /// as "Split with Current" does. Returns false when this window has no
    /// such tab outside a split, so the caller opens the URL instead.
    func commitSplitPreview(pairingTabWithURL url: String) -> Bool {
        guard var preview = pendingSplitPreview, !preview.isCommitted,
              let match = tabs.first(where: {
                  $0.guid != preview.partnerTabId && $0.url == url
                      && splitGroup(forTabId: $0.guid) == nil
              }) else { return false }
        makeTabNormalOpened(tabId: match.guid)
        makeTabNormalOpened(tabId: preview.partnerTabId)
        guard createSplit(leftTabId: preview.partnerTabId, rightTabId: match.guid,
                          layout: .vertical) != nil else { return false }
        preview.isCommitted = true
        pendingSplitPreview = preview
        expireCommittedSplitPreview(preview)
        return true
    }

    /// The preview stays up until the real split replaces it
    /// (`handleSplitCreated`); this covers a split that never arrives.
    private func expireCommittedSplitPreview(_ preview: PendingSplitPreview) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.pendingSplitPreview == preview else { return }
            self.pendingSplitPreview = nil
        }
    }

    /// The omnibox closed. An uncommitted preview returns to the single tab.
    func endSplitPreview() {
        guard pendingSplitPreview?.isCommitted == false else { return }
        pendingSplitPreview = nil
    }

    /// Opens a fresh tab (on `partnerNavigateURL` when given, else a
    /// new-tab page) and, once Chromium echoes it back, pairs it with
    /// `partnerTabId` into a split.
    /// - Parameters:
    ///   - newTabSlot: Where the new tab should end up. Defaults to `.right`
    ///     (right-click "Open as Split" — right-clicked tab stays on the
    ///     left, new tab opens on the right). Pass `.left` to drop the new
    ///     tab on the left and leave the partner on the right.
    ///   - layout: Orientation of the resulting split (`.vertical` = side-by-
    ///     side, `.horizontal` = stacked). Defaults to `.vertical`.
    ///   - partnerNavigateURL: When non-nil, the new pane is created directly
    ///     on this URL instead of landing on a new-tab page first, so the
    ///     NTP never flashes before the real page. Used by the
    ///     open-link-as-split and split-bookmark paths.
    ///   - boundBookmarkGuid: When non-nil, the resulting split's id is
    ///     registered in `splitBookmarkBindings` under this bookmark guid so
    ///     a subsequent click on the bookmark activates the existing split.
    /// - Returns: `true` when the new-tab split command was dispatched.
    @discardableResult
    func openNewTabAsSplit(partnerTabId: Int,
                           newTabSlot: SplitSlot = .right,
                           partnerNavigateURL: String? = nil,
                           additionalPaneURLs: [String] = [],
                           boundBookmarkGuid: String? = nil,
                           insertionIndex: Int? = nil,
                           closePartnerOnTimeout: Bool = false,
                           layout: SplitLayout = .vertical) -> Bool {
        guard splitGroup(forTabId: partnerTabId) == nil else { return false }
        // Splits never live in the pinned strip. If the partner is currently
        // pinned, demote it to the normal list first and leave a fresh
        // unopened pinned placeholder pointing at the same URL at the
        // original pinned slot, so the user sees the pinned entry stay put
        // while the live tab participates in the new split below.
        demotePinnedTabLeavingPlaceholder(forTabId: partnerTabId)
        return openNewTabPendingSplit(
            PendingSplitPartner(target: .newPair(partnerTabId: partnerTabId,
                                                 newTabSlot: newTabSlot,
                                                 layout: layout),
                                additionalPaneURLs: additionalPaneURLs,
                                boundBookmarkGuid: boundBookmarkGuid,
                                insertionIndex: insertionIndex,
                                closePartnerOnTimeout: closePartnerOnTimeout),
            navigateURL: partnerNavigateURL)
    }

    /// Opens a fresh tab (on `navigateURL` when given, else a new-tab page)
    /// and, once Chromium echoes it back, adds it to the existing split
    /// `splitId` as pane `slot`. Refused for a full split. A pinned or
    /// bookmark-bound split moves to the normal tab list first.
    @discardableResult
    func openNewTabIntoSplit(splitId: String, slot: Int, navigateURL: String?) -> Bool {
        guard splitGroup(forId: splitId)?.canAddPane == true,
              makeSplitNormalOpened(splitId) else { return false }
        return openNewTabJoiningSplit(splitId: splitId, slot: slot, navigateURL: navigateURL)
    }

    /// `openNewTabIntoSplit` without moving the split, for a split reopening
    /// its own saved panes: those stay wherever the split is bound.
    private func openNewTabJoiningSplit(splitId: String, slot: Int, navigateURL: String?) -> Bool {
        guard let group = splitGroup(forId: splitId), group.canAddPane, !group.isPinned else {
            return false
        }
        return openNewTabPendingSplit(
            PendingSplitPartner(target: .existingSplit(splitId: splitId,
                                                       slot: max(0, min(slot, group.paneCount)))),
            navigateURL: navigateURL)
    }

    /// The shared tail of `openNewTabAsSplit` and `openNewTabIntoSplit`:
    /// creates the tab under a pending-partner marker and arms the timeout.
    private func openNewTabPendingSplit(_ pending: PendingSplitPartner,
                                        navigateURL: String?) -> Bool {
        guard ChromiumLauncher.sharedInstance().bridge != nil else { return false }
        let pendingGuid = SplitPendingGuid.partner.mint()
        pendingSplitPartnerByCustomGuid[pendingGuid] = pending
        // Mark the partner panes BEFORE `createTab`. Chromium's active-tab
        // handler runs synchronously inside the new-tab creation and would
        // otherwise drive the existing panes through OCCLUDED → pending-hide
        // → HIDDEN. The mark suppresses that bounce so their
        // `RenderWidgetHostViewCocoa` never has to attempt a HIDDEN → VISIBLE
        // resume — the root cause of the blank-pane symptom. Cleared in
        // `consumePendingSplitPartner` and (idempotently) by Chromium once
        // the split is established.
        let partnerIds = pending.partnerTabIds(in: self)
        for partnerId in partnerIds {
            ChromiumLauncher.sharedInstance().bridge?
                .markPendingSplitPartner(withTabId: partnerId.int64Value,
                                         windowId: windowId.int64Value)
        }
        // Create the pane directly on the target URL when one was supplied —
        // parking it on NTP and navigating after the echo flashes the
        // new-tab page first. The initial load of a fresh tab cannot trip
        // CrossDomainNewTabNavigationThrottle even though the customGuid
        // marker is still set: a brand-new WebContents has no committed URL
        // and the load has no initiator origin, so the throttle's source-URL
        // check never passes.
        let createURL =
            (navigateURL?.isEmpty == false) ? navigateURL! : "chrome://newtab"
        // An incognito pane landing on the NTP must use the NATIVE new-tab
        // page, exactly like Cmd+T (`newBrowserTab`) — the Chromium
        // chrome://newtab renders blank off-the-record. Without the enqueue
        // the arriving tab misses `usesNativeNTP` and its pane shows the
        // blank Chromium contents.
        if isIncognito, navigateURL?.isEmpty != false {
            enqueueNativeNTP()
        }
        createTab(createURL, customGuid: pendingGuid, focusAfterCreate: true)
        // Timeout cleanup: if the new tab never arrives (Chromium failure,
        // partner closed mid-flight, etc.), drop the pending record and clear
        // the visibility-skip marks so the partners can hide normally again.
        let wid = windowId
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            guard let pending = self.pendingSplitPartnerByCustomGuid.removeValue(forKey: pendingGuid) else {
                return  // already consumed
            }
            for partnerId in partnerIds {
                ChromiumLauncher.sharedInstance().bridge?
                    .clearPendingSplitPartner(withTabId: partnerId.int64Value,
                                              windowId: wid.int64Value)
            }
            self.listPanesNoLongerOpeningBehindBookmark(partnerIds)
            if pending.closePartnerOnTimeout, case .newPair(let partnerId, _, _) = pending.target {
                self.tabs.first(where: { $0.guid == partnerId })?
                    .webContentWrapper?.close()
            }
        }
        return true
    }

    /// Right-click "Open as Split" on an *unopened* pinned cell. The pinned
    /// record's synthetic `guid` is not a live Chromium tab id, so it can't be
    /// fed directly to `openNewTabAsSplit`. Instead, record the intent against
    /// the DB guid and materialize the pinned tab via `createTab` with the
    /// pinned `customGuid`; `handleNewTabFromChromium` drains
    /// `pendingSplitAfterPinnedOpen` once the live counterpart arrives and
    /// then runs the standard split-formation path.
    func openNewTabAsSplitFromUnopenedPinned(pinnedDBGuid: String, url: String) {
        guard !pinnedDBGuid.isEmpty, !url.isEmpty else { return }
        pendingSplitAfterPinnedOpen.insert(pinnedDBGuid)
        createTab(url, customGuid: pinnedDBGuid, focusAfterCreate: true)
    }

    /// Called from `handleNewTabFromChromium`. If the arriving tab matches a
    /// pending split request keyed by its customGuid, create the split (or
    /// add the tab to the pending split) now.
    func consumePendingSplitPartner(for tab: Tab) {
        guard let customGuid = tab.guidInLocalDB,
              SplitPendingGuid.partner.matches(customGuid) else {
            return
        }
        // Drop the transient pairing marker on both sides. On Swift it keeps
        // `isPinnedOrInDB` from latching true; on Chromium it stops
        // CrossDomainNewTabNavigationThrottle from treating the pane as a
        // pinned/bookmark tab and redirecting cross-domain typing into a fresh
        // tab. Without the bridge call the throttle still fires even after
        // `guidInLocalDB` is cleared. This must happen even when the pending
        // record has already expired (echo arrived after the 5s timeout in
        // `openNewTabAsSplit`) — a latched marker hijacks the tab forever.
        tab.guidInLocalDB = nil
        tab.webContentWrapper?.updateTabCustomValue("")
        guard let pending = pendingSplitPartnerByCustomGuid.removeValue(forKey: customGuid) else {
            return
        }
        // From here on, every exit path must clear the visibility-skip mark
        // on the partners — Chromium clears it idempotently on success, but
        // the early-return guards below would otherwise leave a permanent
        // skip latched on the partner tabs.
        let partnerIds = pending.partnerTabIds(in: self)
        let arrivedTabId = tab.guid
        let clearPartnerMarks: () -> Void = { [weak self] in
            guard let self else { return }
            for partnerId in partnerIds {
                ChromiumLauncher.sharedInstance().bridge?
                    .clearPendingSplitPartner(withTabId: partnerId.int64Value,
                                              windowId: self.windowId.int64Value)
            }
            // Every caller is a request that produced no split, so panes
            // that were hidden for a bookmark-bound one are plain tabs.
            self.listPanesNoLongerOpeningBehindBookmark(partnerIds + [arrivedTabId])
        }

        switch pending.target {
        case let .existingSplit(splitId, slot):
            guard let group = splitGroup(forId: splitId), group.canAddPane, !group.isPinned,
                  !group.contains(tabId: tab.guid) else {
                clearPartnerMarks()
                return
            }
            tabsAwaitingSplit.insert(tab.guid)
            MainActor.assumeIsolated {
                focuseTab(tab)
            }
            // A pane of a grouped split joins the group before the strip
            // move, for the same reason as the new-pair path below.
            if let groupToken = tabs.first(where: { $0.guid == group.firstTabId })?.groupToken {
                ChromiumLauncher.sharedInstance().bridge?.addTabsToGroup(
                    withWindowId: Int64(windowId),
                    tabIds: [NSNumber(value: Int64(tab.guid))],
                    tokenHex: groupToken)
                MainActor.assumeIsolated {
                    applyOptimisticGroupMembership(tabId: tab.guid, newToken: groupToken)
                }
            }
            ChromiumLauncher.sharedInstance().bridge?.addTab(toSplit: splitId,
                                                             tabId: tab.guid.int64Value,
                                                             slotIndex: Int32(slot),
                                                             windowId: windowId.int64Value)
            // Chromium clears the marks when the pane lands; this covers a
            // declined add (the split dissolved meanwhile).
            let tabId = tab.guid
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                if self.tabsAwaitingSplit.remove(tabId) != nil {
                    clearPartnerMarks()
                }
            }
            return

        case let .newPair(partnerTabId, newTabSlot, layout):
            guard partnerTabId != tab.guid,
                  splitGroup(forTabId: partnerTabId) == nil else {
                clearPartnerMarks()
                return
            }
            // Before the focus moves to it below (see `tabsAwaitingSplit`).
            tabsAwaitingSplit.insert(tab.guid)
            // Sync Mac's focus to the new tab before `createSplit`. The new tab
            // was created with `focusAfterCreate: true`, so Chromium has
            // already activated it, but Chromium's `activeTabChanged` event may
            // not have reached Mac yet — `focusingTab` would still point at the
            // partner, leaving Mac's state (sidebar selection, address-bar
            // routing) stuck on the partner.
            // `focuseTab` is statically @MainActor but at runtime this whole flow
            // arrives via EventBus's `Task { @MainActor in ... }` dispatch.
            MainActor.assumeIsolated {
                focuseTab(tab)
            }
            // If the partner sits in a tab group, pull the new pane into the
            // same group BEFORE the placeTabAdjacent / createSplit calls so the
            // split stays at the partner's position. Doing the add afterwards
            // works for membership but Chromium's `AddToExistingGroup` always
            // relocates the joining tabs to the trailing edge of the group's
            // strip range — the split would visibly jump to the end of the
            // group. Setting membership first keeps the new tab inside the run
            // and `placeTabAdjacent`'s relocate-interloper guard becomes a no-op
            // (both panes share the token), so the pair lands exactly where the
            // partner was.
            //
            // `applyOptimisticGroupMembership` is `@MainActor`; mirror the
            // `focuseTab` call above — this flow arrives via EventBus's
            // `Task { @MainActor in ... }` dispatch, so `assumeIsolated` is safe.
            if let partnerToken = tabs.first(where: { $0.guid == partnerTabId })?.groupToken {
                ChromiumLauncher.sharedInstance().bridge?.addTabsToGroup(
                    withWindowId: Int64(windowId),
                    tabIds: [NSNumber(value: Int64(tab.guid))],
                    tokenHex: partnerToken)
                MainActor.assumeIsolated {
                    applyOptimisticGroupMembership(tabId: tab.guid, newToken: partnerToken)
                }
            }
            // Bridge-created tabs land at the end of the strip when no
            // `insertAfterTabId` hint is provided, so the new pane would sit far
            // from its partner if the right-clicked tab wasn't the active tab.
            // Make them adjacent first so `createSplit` doesn't leave unrelated
            // tabs between the two panes in the sidebar.
            placeTabAdjacent(tabId: tab.guid,
                             to: partnerTabId,
                             on: newTabSlot)
            let createdSplitId: String?
            switch newTabSlot {
            case .right:
                createdSplitId = createSplit(leftTabId: partnerTabId,
                                             rightTabId: tab.guid,
                                             layout: layout)
            case .left:
                createdSplitId = createSplit(leftTabId: tab.guid,
                                             rightTabId: partnerTabId,
                                             layout: layout)
            }
            // Closed-split drop: both panes were just materialized here, so they
            // sit at the tail of the strip. Record the requested drop index
            // against the new split id; `handleSplitCreated` relocates the pair
            // once Chromium echoes the split back.
            if let insertionIndex = pending.insertionIndex,
               let splitId = createdSplitId {
                pendingSplitMoveToNormalIndexByCreateId[splitId] = insertionIndex
            }
            // A wider closed split: the remaining panes join as soon as
            // Chromium has echoed the split back (`handleSplitCreated`).
            if !pending.additionalPaneURLs.isEmpty, let splitId = createdSplitId {
                pendingSplitAdditionalPaneURLsById[splitId] = pending.additionalPaneURLs
            }
            // Track the bookmark → split pairing so a second click on the same
            // split-view bookmark re-activates this split instead of opening
            // another duplicate. Cleared in `handleSplitRemoved`.
            if let bookmarkGuid = pending.boundBookmarkGuid, !bookmarkGuid.isEmpty,
               let splitId = createdSplitId {
                splitBookmarkBindings[bookmarkGuid] = splitId
                syncSplitBookmarkOpenedState(bookmarkGuid: bookmarkGuid)
                // Re-filter the sidebar tab list so the two split panes hide
                // behind the split-view bookmark cell instead of duplicating
                // as their own tab rows.
                updateNormalTabs()
            }
            // Idempotent backstop: Chromium's `CreateSplit` already clears the
            // mark when `AddToNewSplit` succeeds; this covers the case where the
            // bridge `createSplit` returned nil (e.g. tabs disappeared between
            // the placeTabAdjacent call and the bridge call).
            if createdSplitId == nil {
                clearPartnerMarks()
                tabsAwaitingSplit.remove(tab.guid)
            }
        }
    }

    // MARK: - Replace a split pane (drag onto an existing split)

    /// Whether replacing pane `slotIndex` of `splitId` should preserve the
    /// evicted pane as a standalone tab next to the split
    /// (`swapTabInSplit(swap: true)`). An empty new-tab page is *not*
    /// preserved — it would just litter the strip, so the caller passes
    /// `swap: false` to close it instead. Returns true (preserve) when the
    /// split or evicted tab can't be resolved.
    func splitPaneReplacementKeepsEvicted(splitId: String, slotIndex: Int) -> Bool {
        guard let group = splitGroup(forId: splitId),
              slotIndex >= 0, slotIndex < group.paneCount else { return true }
        let evictedTabId = group.tabIds[slotIndex]
        return tabs.first(where: { $0.guid == evictedTabId })?.isNTP != true
    }

    /// Opens a fresh tab directly on `url` and, once Chromium echoes it back,
    /// swaps it into the given split slot via `swapTabInSplit(..., swap: true)`
    /// so the evicted pane lands right next to the split. Used by the
    /// drag-onto-split-pane flow for the bookmark and closed-pinned sources,
    /// which have no live tab id to swap directly. Creating the tab on `url`
    /// (instead of NTP plus a deferred navigate) is throttle-safe — see the
    /// initial-load note in `openNewTabPendingSplit`.
    func openTabAsPaneReplacement(splitId: String, slotIndex: Int, url: String) {
        guard splitGroup(forId: splitId) != nil, !url.isEmpty else { return }
        let pendingGuid = SplitPendingGuid.swapSlot.mint()
        pendingSplitSlotSwapByCustomGuid[pendingGuid] = PendingSplitSlotSwap(
            splitId: splitId,
            slotIndex: slotIndex
        )
        // Open in the background: focusing the new tab would flash it
        // full-screen over the split before the swap pulls it into the pane.
        createTab(url, customGuid: pendingGuid, focusAfterCreate: false)
        // Timeout cleanup: if the new tab never arrives, drop the pending
        // record so it can't fire a stale swap later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            guard self.pendingSplitSlotSwapByCustomGuid[pendingGuid] != nil else {
                return  // already consumed
            }
            self.pendingSplitSlotSwapByCustomGuid.removeValue(forKey: pendingGuid)
        }
    }

    /// Called from `handleNewTabFromChromium`. If the arriving tab matches a
    /// pending pane-replacement request keyed by its customGuid, swap it
    /// into the recorded split slot now.
    func consumePendingSplitSlotSwap(for tab: Tab) {
        guard let customGuid = tab.guidInLocalDB,
              SplitPendingGuid.swapSlot.matches(customGuid) else {
            return
        }
        // Drop the transient marker on both sides so it doesn't latch a
        // pinned/bookmark binding or trigger CrossDomainNewTabNavigationThrottle.
        // This must happen even when the pending record has already expired
        // (echo arrived after the 5s timeout below) — a latched marker keeps
        // `isPinnedOrInDB` true and the throttle hijacking the tab's
        // cross-domain navigations forever.
        tab.guidInLocalDB = nil
        tab.webContentWrapper?.updateTabCustomValue("")
        guard let pending = pendingSplitSlotSwapByCustomGuid.removeValue(forKey: customGuid) else {
            return
        }
        // The split may have been dismantled between the open and the echo
        // (pane closed, window torn off). Re-validate before swapping.
        guard let group = splitGroup(forId: pending.splitId),
              pending.slotIndex < group.paneCount else { return }
        // Close the evicted pane if it's an empty new-tab page; otherwise keep
        // it as a standalone tab.
        let keepEvicted = splitPaneReplacementKeepsEvicted(splitId: pending.splitId,
                                                           slotIndex: pending.slotIndex)
        swapTabInSplit(pending.splitId,
                       slotIndex: pending.slotIndex,
                       withTabId: tab.guid,
                       swap: keepEvicted)
    }

    // MARK: - Open-URL-as-split (bookmark "Open as Split")

    /// Opens `url` as a new tab and, once Chromium echoes it back, creates a
    /// fresh new-tab-page partner and splits the pair. The arriving URL tab
    /// is the primary (left) pane; the NTP is the secondary (right) pane.
    /// Used by the bookmark "Open as Split" menu.
    func openURLAsSplit(url: String) {
        let pendingGuid = SplitPendingGuid.primary.mint()
        pendingPrimarySplitTargetByGuid[pendingGuid] = PendingPrimarySplit(
            secondaryURL: nil
        )
        // Create the tab directly on `url` — throttle-safe for the initial
        // load, see the note in `openNewTabPendingSplit`.
        createTab(url, customGuid: pendingGuid, focusAfterCreate: true)
        schedulePendingPrimarySplitCleanup(pendingGuid: pendingGuid)
    }

    /// Opens two URLs as a side-by-side split. The first becomes the primary
    /// (left) pane and the second becomes the partner (right) pane. Used by
    /// the split-view bookmark click flow — both URLs are stored on a single
    /// `Bookmark`, and opening it restores the original pair.
    /// - Parameter bookmarkGuid: When non-nil, the panes are rebound to
    ///   this bookmark guid once they finish navigating, so the bookmark
    ///   tracks the open split and a subsequent click activates the existing
    ///   split instead of opening another one.
    ///
    /// `urls` holds two to four URLs in slot order. The first two form the
    /// split; each further URL joins it as a new pane once it is up.
    func openURLsAsSplit(_ urls: [String],
                         bookmarkGuid: String? = nil,
                         groupToken: String? = nil,
                         insertionIndex: Int? = nil,
                         layout: SplitLayout = .vertical) {
        guard urls.count >= 2 else { return }
        let pendingGuid = SplitPendingGuid.primary.mint()
        pendingPrimarySplitTargetByGuid[pendingGuid] = PendingPrimarySplit(
            secondaryURL: urls[1],
            additionalURLs: Array(urls.dropFirst(2).prefix(SplitGroup.maxPaneCount - 2)),
            boundBookmarkGuid: bookmarkGuid,
            groupToken: groupToken,
            insertionIndex: insertionIndex,
            layout: layout
        )
        createTab(urls[0], customGuid: pendingGuid, focusAfterCreate: true)
        schedulePendingPrimarySplitCleanup(pendingGuid: pendingGuid)
    }

    /// Timeout cleanup shared by the two primary-split openers: if the new
    /// tab never arrives, drop the pending record so it can't fire a stale
    /// split later. Mirrors the 5s cleanup in `openNewTabPendingSplit` and
    /// `openTabAsPaneReplacement`.
    private func schedulePendingPrimarySplitCleanup(pendingGuid: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            guard self.pendingPrimarySplitTargetByGuid[pendingGuid] != nil else {
                return  // already consumed
            }
            self.pendingPrimarySplitTargetByGuid.removeValue(forKey: pendingGuid)
        }
    }

    /// Called from `handleNewTabFromChromium`. If the arriving tab is marked
    /// as a pending-primary split, kick off the partner that completes
    /// the pair through the regular `openNewTabAsSplit` path. When the
    /// pending record carries a `secondaryURL` (split-bookmark open), pass
    /// it through so the partner pane is created on that URL instead of NTP.
    func consumePendingPrimarySplit(for tab: Tab) {
        guard let customGuid = tab.guidInLocalDB,
              SplitPendingGuid.primary.matches(customGuid) else {
            return
        }
        // Same cleanup as `consumePendingSplitPartner`: drop the transient
        // marker on both sides so it doesn't latch a pinned/bookmark binding
        // or trigger CrossDomainNewTabNavigationThrottle. Cleared even when
        // the pending record has already expired (echo arrived after the 5s
        // timeout) so the marker can't stay latched on the tab.
        tab.guidInLocalDB = nil
        tab.webContentWrapper?.updateTabCustomValue("")
        guard let pending = pendingPrimarySplitTargetByGuid.removeValue(forKey: customGuid) else {
            return
        }
        // Group drop: pull the primary pane into the destination group before
        // the partner is created. `consumePendingSplitPartner` reads the
        // partner's (this primary's) group token and folds the new pane into
        // the same group, so the finished split lands inside the group.
        if let groupToken = pending.groupToken, !groupToken.isEmpty {
            ChromiumLauncher.sharedInstance().bridge?.addTabsToGroup(
                withWindowId: Int64(windowId),
                tabIds: [NSNumber(value: Int64(tab.guid))],
                tokenHex: groupToken)
            MainActor.assumeIsolated {
                applyOptimisticGroupMembership(tabId: tab.guid, newToken: groupToken)
            }
        }
        let requested = openNewTabAsSplit(partnerTabId: tab.guid,
                                          newTabSlot: .right,
                                          partnerNavigateURL: pending.secondaryURL,
                                          additionalPaneURLs: pending.additionalURLs,
                                          boundBookmarkGuid: pending.boundBookmarkGuid,
                                          insertionIndex: pending.insertionIndex,
                                          layout: pending.layout)
        if !requested {
            listPanesNoLongerOpeningBehindBookmark([tab.guid])
        }
    }

    // MARK: - Panes opening behind a bookmark

    /// Whether the tab arriving under `customGuid` is a pane of a split that
    /// hides behind a bookmark: one of the first two panes of a split its
    /// bookmark is opening, or a saved pane joining a split already bound.
    /// Such a pane is tracked in `splitPaneIdsOpeningBehindBookmark`.
    func isPaneOpeningBehindBookmark(customGuid: String?) -> Bool {
        guard let customGuid else { return false }
        if let primary = pendingPrimarySplitTargetByGuid[customGuid] {
            return primary.boundBookmarkGuid?.isEmpty == false
        }
        guard let partner = pendingSplitPartnerByCustomGuid[customGuid] else { return false }
        switch partner.target {
        case .newPair:
            return partner.boundBookmarkGuid?.isEmpty == false
        case .existingSplit(let splitId, _):
            return splitBookmarkBindings.values.contains(splitId)
        }
    }

    /// The split `tabIds` were opening into is not coming: list the ones
    /// that were hidden for it as normal tabs.
    func listPanesNoLongerOpeningBehindBookmark(_ tabIds: [Int]) {
        guard !splitPaneIdsOpeningBehindBookmark.isDisjoint(with: tabIds) else { return }
        splitPaneIdsOpeningBehindBookmark.subtract(tabIds)
        updateNormalTabs()
    }

}

/// Which side of an existing tab a new pane goes, in user-facing left/right
/// terms rather than slot numbers.
enum SplitSlot {
    /// Slot 0 (top for `.horizontal`, left for `.vertical`).
    case left
    /// Slot 1 (bottom for `.horizontal`, right for `.vertical`).
    case right
}

struct PendingSplitPreview: Equatable {
    /// The focused tab shown beside the blank pane.
    let partnerTabId: Int
    /// The omnibox submitted; the real split is on its way.
    var isCommitted = false
}

/// Stored alongside a pending new-tab request so `consumePendingSplitPartner`
/// can pair the arriving tab with the right partner on the right side, or
/// add it to the right split at the right slot.
struct PendingSplitPartner {
    enum Target {
        /// Pair the arriving tab with `partnerTabId`, the new tab taking
        /// `newTabSlot`. `layout` is kept because the tab arrives
        /// asynchronously after a top/bottom drag requested a stacked split.
        case newPair(partnerTabId: Int, newTabSlot: SplitSlot, layout: SplitLayout)
        /// Add the arriving tab to `splitId` as pane `slot`.
        case existingSplit(splitId: String, slot: Int)
    }

    let target: Target
    /// URLs of the panes that join once the split is up (a closed split of
    /// three or four panes reopening).
    var additionalPaneURLs: [String] = []
    /// Optional bookmark guid to rebind to the new pane after the throttle
    /// marker is cleared. Used by the split-bookmark open flow so the
    /// bookmark cell stays in sync with the open split.
    var boundBookmarkGuid: String? = nil
    /// Optional destination index (in `normalTabs` space) for the finished
    /// split. Non-nil when a closed split was dropped into the tab list at a
    /// specific spot; `consumePendingSplitPartner` forwards it so
    /// `handleSplitCreated` can relocate the pair off the strip's end.
    var insertionIndex: Int? = nil
    /// Closes the existing partner if its requested pane never arrives.
    /// Used when that partner is a transient bookmark-group seed rather than
    /// user-owned content that should survive a failed split request.
    var closePartnerOnTimeout: Bool = false

    /// The live tabs the arriving pane joins: the partner, or every pane of
    /// the split. They are marked as pending partners so they do not bounce
    /// through HIDDEN while the new tab is created.
    func partnerTabIds(in state: BrowserState) -> [Int] {
        switch target {
        case .newPair(let partnerTabId, _, _):
            return [partnerTabId]
        case .existingSplit(let splitId, _):
            return state.splitGroup(forId: splitId)?.tabIds ?? []
        }
    }
}

/// Stored alongside a pending "open a tab to replace a split pane" request.
/// When the tab arrives from Chromium, `consumePendingSplitSlotSwap` swaps
/// it into `slotIndex` of `splitId` via `swapTabInSplit(..., swap: true)`,
/// leaving the evicted pane as a standalone tab right next to the split.
/// Used by the drag-onto-split-pane flow for the bookmark and closed-pinned
/// sources, which have no live tab to swap directly.
struct PendingSplitSlotSwap {
    let splitId: String
    let slotIndex: Int
}

/// Stored alongside a pending "open URL as primary pane" request. The
/// primary tab is created directly on its URL; `secondaryURL` is non-nil
/// when the caller wants the partner pane created on a specific URL
/// (split-bookmark open) rather than left as a new-tab page.
struct PendingPrimarySplit {
    let secondaryURL: String?
    /// URLs of the panes after the first two, in slot order.
    var additionalURLs: [String] = []
    /// Optional bookmark guid to rebind to both panes once they settle, so
    /// the originating split bookmark tracks the open split.
    var boundBookmarkGuid: String? = nil
    /// Optional tab-group token. When set, the primary pane joins the group
    /// as soon as it's created; the partner pane then inherits the same token
    /// through `consumePendingSplitPartner`'s partner-group lookup, so the
    /// finished split materializes inside the group.
    var groupToken: String? = nil
    /// Optional destination index (in `normalTabs` space) for the finished
    /// split. Threaded through to `PendingSplitPartner.insertionIndex` so the
    /// pair lands at the drop spot instead of the strip's end.
    var insertionIndex: Int? = nil
    /// Layout to apply once both asynchronously-created panes are available.
    var layout: SplitLayout = .vertical
}
