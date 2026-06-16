// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Cocoa

/// Orientation of a Chromium split tab pair.
/// Serialized over the bridge as `"vertical"` / `"horizontal"`.
enum SplitLayout: String {
    /// Side-by-side, divided by a vertical bar.
    case vertical
    /// Stacked, divided by a horizontal bar.
    case horizontal

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
    /// Marker for a tab being opened as the partner pane of an existing tab
    /// (right-click "Open as Split"). Consumed by `consumePendingSplitPartner`.
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

/// Where a tab sits within its split pair, ordered by tab-strip index.
/// Used by the sidebar to render two cells as a single merged rounded bar.
enum SplitPairPosition {
    /// Lower tab-strip index — top cell in the sidebar.
    case first
    /// Higher tab-strip index — bottom cell in the sidebar.
    case second
}

/// Window-scoped mirror of a Chromium `SplitTabId`.
/// The IDs are opaque strings (Token::ToString) — do not parse them.
struct SplitGroup: Equatable {
    let id: String
    var primaryTabId: Int
    var secondaryTabId: Int
    var layout: SplitLayout
    /// Fraction of the container occupied by the primary pane (0.0–1.0).
    var ratio: Double
    /// Pin flag for the split as a unit. Toggled via `toggleSplitPinStatus`.
    /// When true the merged sidebar bar shows a pin indicator; the split
    /// otherwise behaves identically. Window-scoped, not persisted.
    var isPinned: Bool = false

    func contains(tabId: Int) -> Bool {
        primaryTabId == tabId || secondaryTabId == tabId
    }

    /// Given one half of the split, return the other. Lets UI callers stay
    /// in user-facing terms ("partner pane") rather than reaching into the
    /// Chromium-side primary/secondary naming directly.
    func partnerTabId(of tabId: Int) -> Int? {
        if primaryTabId == tabId { return secondaryTabId }
        if secondaryTabId == tabId { return primaryTabId }
        return nil
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

    /// Position of a tab within its split pair, as ordered by the tab strip.
    /// `.first` = lower index (top in sidebar / left in horizontal strip).
    /// `.second` = higher index. Returns nil if not in a split, partner missing,
    /// or the partner is not at an immediately adjacent index — the merged-bar
    /// styling derived from this value assumes physical adjacency, so a
    /// transiently-separated pair must fall back to plain tab rendering rather
    /// than paint a misleading half-bar with a tab sitting between the panes.
    func splitPairPosition(forTabId tabId: Int) -> SplitPairPosition? {
        guard let group = splitGroup(forTabId: tabId) else { return nil }
        let partnerId = group.primaryTabId == tabId ? group.secondaryTabId : group.primaryTabId
        guard let myIdx = normalTabs.firstIndex(where: { $0.guid == tabId }),
              let partnerIdx = normalTabs.firstIndex(where: { $0.guid == partnerId }),
              abs(myIdx - partnerIdx) == 1 else {
            return nil
        }
        return myIdx < partnerIdx ? .first : .second
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
        /// Live `SplitGroup` covering both panes, when both panes are
        /// currently open Chromium tabs. `nil` for closed pinned splits.
        let liveGroup: SplitGroup?
        /// Persisted DB-guid pair for pinned splits (live or closed).
        /// `nil` for non-pinned live splits. Ordered `(left, right)` to
        /// match the on-screen layout.
        let pinnedDBPair: (left: String, right: String)?
        /// Display tab for the left pane (live tab when open, pinned
        /// record otherwise). Ordered to match the on-screen layout.
        let leftPane: Tab
        /// Display tab for the right pane.
        let rightPane: Tab

        /// True iff the cell belongs to a pinned split (live or closed).
        var isPinned: Bool { pinnedDBPair != nil }
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
        guard let primary = tabs.first(where: { $0.guid == group.primaryTabId }),
              let secondary = tabs.first(where: { $0.guid == group.secondaryTabId }) else {
            return nil
        }
        if group.isPinned {
            // Pinned live: order by pinned-grid index so the pair matches the
            // merged-cell layout. Bail when either pane lacks a DB guid (a
            // transient pin/unpin race) so callers don't see a half-formed pair.
            guard let primaryDB = primary.guidInLocalDB, !primaryDB.isEmpty,
                  let secondaryDB = secondary.guidInLocalDB, !secondaryDB.isEmpty,
                  let primaryIdx = pinnedTabs.firstIndex(where: { $0.guidInLocalDB == primaryDB }),
                  let secondaryIdx = pinnedTabs.firstIndex(where: { $0.guidInLocalDB == secondaryDB }) else {
                return nil
            }
            if primaryIdx <= secondaryIdx {
                return SplitMembership(liveGroup: group,
                                       pinnedDBPair: (primaryDB, secondaryDB),
                                       leftPane: primary,
                                       rightPane: secondary)
            }
            return SplitMembership(liveGroup: group,
                                   pinnedDBPair: (secondaryDB, primaryDB),
                                   leftPane: secondary,
                                   rightPane: primary)
        }
        // Non-pinned live: order by tab-strip index.
        let primaryIdx = normalTabs.firstIndex(where: { $0.guid == primary.guid }) ?? 0
        let secondaryIdx = normalTabs.firstIndex(where: { $0.guid == secondary.guid }) ?? 0
        if primaryIdx <= secondaryIdx {
            return SplitMembership(liveGroup: group,
                                   pinnedDBPair: nil,
                                   leftPane: primary,
                                   rightPane: secondary)
        }
        return SplitMembership(liveGroup: group,
                               pinnedDBPair: nil,
                               leftPane: secondary,
                               rightPane: primary)
    }

    private func closedPinnedMembership(pinnedSelf: Tab) -> SplitMembership? {
        guard let (leftDB, rightDB) = pinnedSplitDBPair(forPinnedTab: pinnedSelf) else {
            return nil
        }
        // Prefer the live tab when one pane happens to be open (URL reflects
        // in-browser navigation); fall back to the pinned record otherwise.
        let leftPane = tabs.first(where: { $0.guidInLocalDB == leftDB })
            ?? pinnedTabs.first(where: { $0.guidInLocalDB == leftDB })
        let rightPane = tabs.first(where: { $0.guidInLocalDB == rightDB })
            ?? pinnedTabs.first(where: { $0.guidInLocalDB == rightDB })
        guard let leftPane, let rightPane else { return nil }
        return SplitMembership(liveGroup: nil,
                               pinnedDBPair: (leftDB, rightDB),
                               leftPane: leftPane,
                               rightPane: rightPane)
    }

    /// Resolve the (left, right) `guidInLocalDB` pair for a pinned-split
    /// group that includes `pinnedTab`. Returns `nil` for solo pinned tabs.
    ///
    /// Mirrors the pairing rules used by the sidebar
    /// `PinnedTabViewController.buildTabSectionItems` and the tab strip
    /// `pinnedSplitCollapseInfo` so a click on a pinned-split cell drives
    /// the same routing the rendering already expressed. Pair sources, in
    /// order:
    ///   1. Live `SplitGroup` flagged `isPinned` — covers the common case
    ///      where both panes are currently open Chromium tabs.
    ///   2. Persisted `Tab.splitPartnerGuid` — survives across restarts and
    ///      covers pinned-split records waiting to be reopened.
    /// The returned ordering follows the tabs' positions in `pinnedTabs`
    /// (lower index = left), matching the sidebar / strip layout.
    func pinnedSplitDBPair(forPinnedTab pinnedTab: Tab) -> (String, String)? {
        guard let myDB = pinnedTab.guidInLocalDB, !myDB.isEmpty else { return nil }

        var partnerDB: String?
        if let liveTab = tabs.first(where: { $0.guidInLocalDB == myDB }),
           let group = splits.first(where: { $0.isPinned && $0.contains(tabId: liveTab.guid) }),
           let partnerLiveId = group.partnerTabId(of: liveTab.guid),
           let partnerLive = tabs.first(where: { $0.guid == partnerLiveId }) {
            partnerDB = partnerLive.guidInLocalDB
        }
        if partnerDB == nil, let persisted = pinnedTab.splitPartnerGuid, !persisted.isEmpty {
            partnerDB = persisted
        }
        guard let partnerDB,
              let myIdx = pinnedTabs.firstIndex(where: { $0.guidInLocalDB == myDB }),
              let partnerIdx = pinnedTabs.firstIndex(where: { $0.guidInLocalDB == partnerDB }) else {
            return nil
        }
        return myIdx < partnerIdx ? (myDB, partnerDB) : (partnerDB, myDB)
    }

    /// Unpin a persisted pinned split whose live `SplitGroup` no longer
    /// exists (both panes are closed). Drops the persisted partner pairing,
    /// removes the two pinned records, and reopens the pair as a fresh
    /// non-pinned split — matching what `toggleSplitPinStatus` does for the
    /// active case where both panes were live.
    @MainActor
    func unpinClosedPinnedSplit(leftDB: String, rightDB: String, insertionIndex: Int? = nil) {
        guard let leftPinned = pinnedTabs.first(where: { $0.guidInLocalDB == leftDB }),
              let rightPinned = pinnedTabs.first(where: { $0.guidInLocalDB == rightDB }),
              let leftURL = leftPinned.url, !leftURL.isEmpty,
              let rightURL = rightPinned.url, !rightURL.isEmpty else {
            return
        }
        leftPinned.splitPartnerGuid = nil
        rightPinned.splitPartnerGuid = nil
        localStore.updateTabSplitPartner(leftDB, partnerGuid: nil)
        localStore.updateTabSplitPartner(rightDB, partnerGuid: nil)
        localStore.removePinnedTab(leftPinned)
        localStore.removePinnedTab(rightPinned)
        openTwoURLsAsSplit(primaryURL: leftURL, secondaryURL: rightURL, insertionIndex: insertionIndex)
    }

    /// True when one of the tabs in the split is currently the focusing tab.
    /// Used to render the split-pair background as "active group" vs. "passive group".
    func isSplitGroupActive(_ group: SplitGroup) -> Bool {
        guard let focused = focusingTab else { return false }
        return group.contains(tabId: focused.guid)
    }

    /// True when both tabs in a freshly-reported split correspond to pinned
    /// tab records in `pinnedTabs`. Used at split-creation time to seed
    /// `SplitGroup.isPinned` so restored/recreated pinned splits render as
    /// one cell without waiting on a Mac-side toggle.
    func isSplitMembersAllPinned(primaryId: Int, secondaryId: Int) -> Bool {
        guard let primaryLive = tabs.first(where: { $0.guid == primaryId }),
              let primaryDB = primaryLive.guidInLocalDB,
              let secondaryLive = tabs.first(where: { $0.guid == secondaryId }),
              let secondaryDB = secondaryLive.guidInLocalDB else {
            return false
        }
        let pinnedDBGuids = Set(pinnedTabs.compactMap { $0.guidInLocalDB })
        return pinnedDBGuids.contains(primaryDB) && pinnedDBGuids.contains(secondaryDB)
    }

    /// Flattened tabId → partnerTabId lookup across all split groups in this window.
    /// Consumed by tab-insertion logic so a link opened from a split tab lands after
    /// the whole split pair instead of between its two panes.
    func splitPartnerByTabIdMap() -> [Int: Int] {
        splits.reduce(into: [:]) { result, group in
            result[group.primaryTabId] = group.secondaryTabId
            result[group.secondaryTabId] = group.primaryTabId
        }
    }

    /// Lower-index positions of split pairs whose two members sit adjacent in
    /// `normalTabs`. Consumed by the tab-strip drag controller to keep the
    /// drop indicator from landing between the two panes.
    func splitPairLowerIndicesInNormalTabs() -> Set<Int> {
        splits.reduce(into: Set<Int>()) { result, group in
            guard let aIdx = normalTabs.firstIndex(where: { $0.guid == group.primaryTabId }),
                  let bIdx = normalTabs.firstIndex(where: { $0.guid == group.secondaryTabId }) else {
                return
            }
            let lo = min(aIdx, bIdx)
            let hi = max(aIdx, bIdx)
            if hi == lo + 1 {
                result.insert(lo)
            }
        }
    }

    /// If `toIndex` would drop a tab strictly between the two members of a
    /// split pair, return the closest legal index on the side that matches the
    /// drag direction. Split tabs are always adjacent in the tab strip, so for
    /// a pair at positions (k, k+1) the only forbidden insertion index is k+1.
    /// Caller is responsible for the early-return when the dragged tab itself
    /// belongs to a split (those moves go through `moveSplit`, not this path).
    ///
    /// Reuses `splitPairLowerIndicesInNormalTabs` as the single source of the
    /// pair-adjacency arithmetic; the tab-strip drag controller's
    /// `snapGapOutsideSplitPair` consumes the same set, so the "where do the
    /// pairs sit" logic lives in exactly one place on the Swift side.
    func snapDropOutsideSplitPair(toIndex: Int, fromIndex: Int) -> Int {
        // `toIndex` is the forbidden slot k+1 iff the index just before it (k)
        // is a pair's lower member.
        let lowerIndex = toIndex - 1
        guard splitPairLowerIndicesInNormalTabs().contains(lowerIndex) else {
            return toIndex
        }
        // Snap past the pair (lowerIndex, lowerIndex+1) on whichever side
        // matches the drag direction.
        return fromIndex <= lowerIndex ? lowerIndex + 2 : lowerIndex
    }

    // MARK: - Chromium → Mac handlers

    @MainActor
    func handleSplitCreated(splitId: String,
                            primaryTabId: Int,
                            secondaryTabId: Int,
                            layout: SplitLayout,
                            ratio: Double) {
        // `pendingSplitPrimaryByCreateId` is written synchronously by
        // `createSplit(leftTabId:rightTabId:)` and consumed here once
        // Chromium echoes the split back. The contract assumes a main-thread
        // hop on the bridge side — verify so a reentrant non-main delivery
        // doesn't silently lose the orientation hint.
        assert(Thread.isMainThread, "handleSplitCreated must run on the main thread")
        // Chromium always reports the lower-tab-strip-indexed tab as
        // `primaryTabId`. If the caller asked for a specific tab on the
        // left/primary side, publish the corrected orientation up front and
        // ask Chromium to match. Storing the wrong orientation first and then
        // reversing causes the focused tab's webContentView to be reparented
        // twice in quick succession; the second mount lands a Chromium
        // renderer that hasn't been re-driven and the pane shows blank.
        let intendedPrimary = pendingSplitPrimaryByCreateId.removeValue(forKey: splitId)
        let needsReverse = intendedPrimary != nil
            && intendedPrimary != primaryTabId
            && intendedPrimary == secondaryTabId
        let storedPrimary = needsReverse ? secondaryTabId : primaryTabId
        let storedSecondary = needsReverse ? primaryTabId : secondaryTabId

        // A split that involves two already-pinned tabs is itself pinned.
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
        let pinnedFlag = forcedPinned
            || isSplitMembersAllPinned(primaryId: storedPrimary,
                                       secondaryId: storedSecondary)
        let group = SplitGroup(id: splitId,
                               primaryTabId: storedPrimary,
                               secondaryTabId: storedSecondary,
                               layout: layout,
                               ratio: ratio,
                               isPinned: pinnedFlag)
        if let index = splits.firstIndex(where: { $0.id == splitId }) {
            splits[index] = group
        } else {
            splits.append(group)
        }

        // `consumePendingSplitPartner` already called `placeTabAdjacent`,
        // but a Chromium `tabIndicesUpdated` echo for the just-created
        // partner tab can land between that placement and this handler and
        // re-sequence `normalTabOrder` back to the pre-placement order via
        // `reorderTabs`. Re-assert adjacency now that the SplitGroup is in
        // `splits`, and republish so the sidebar / tab strip re-render.
        if enforceSplitAdjacency() {
            updateNormalTabs()
        }

        if needsReverse {
            // Defer one main-actor hop. `handleSplitCreated` is dispatched
            // via `Task { @MainActor }` from a TabStripModel observer
            // callback; under contention that Task can land while Chromium
            // is still mid-mutation, and `TabStripModel::ReverseTabsInSplit`
            // hard-CHECKs its reentrancy guard. Re-checking `splitGroup`
            // also drops the bridge call if the split was torn down in the
            // meantime, since the C++ side past `ContainsSplit` has no
            // defensive null check on `GetSplitData`.
            Task { @MainActor [weak self] in
                guard let self, self.splitGroup(forId: splitId) != nil else { return }
                self.reverseTabsInSplit(splitId)
            }
        }

        // Closed-split drop relocation: a split opened from a closed bookmark
        // or unopened pinned pair was materialized at the strip's end (its
        // panes are bridge-created tabs with no insert hint). Now that the
        // SplitGroup exists, move the pair as a unit to the drop index the
        // user released on. Deferred for the same reason as the reverse above
        // — running synchronously can land mid-Chromium-mutation and trip
        // `MoveSplitTo`'s reentrancy guard — and scheduled after the reverse
        // Task so the two strip mutations stay ordered. Re-resolve the group
        // inside the Task since it may have been reversed or torn down.
        if let targetIndex = pendingSplitMoveToNormalIndexByCreateId.removeValue(forKey: splitId) {
            Task { @MainActor [weak self] in
                guard let self, let liveGroup = self.splitGroup(forId: splitId) else { return }
                self.moveSplitPairOrderLocally(group: liveGroup, to: targetIndex)
            }
        }

        // `consumePendingSplitPartner` registers the bookmark→split binding
        // immediately after `createSplit` returns, but at that point this
        // group hasn't been appended to `splits` yet — the bridge call is
        // synchronous from Swift but Chromium echoes the split back here
        // asynchronously. Refilter now so the two panes hide behind the
        // bookmark cell without waiting for an unrelated tab event.
        if splitBookmarkBindings.values.contains(splitId) {
            updateNormalTabs()
        }

        reconcileSplitChatBinding(group)
        syncSplitAIChatCollapsed(group)
    }

    /// Sync both panes of a freshly-created split to one AI Chat collapse
    /// state, so switching the active pane does not toggle the sidebar
    /// between collapsed and expanded.
    ///
    /// Bias toward expanded: if either pane has chat open, keep both open.
    /// The freshly-opened partner ("open in split view" / drag-to-split)
    /// lands on NTP with `aiChatCollapsed = true` (the default) and is
    /// often the focused pane when this runs, so picking the focused pane's
    /// state would yank the other pane's open chat shut.
    @MainActor
    func syncSplitAIChatCollapsed(_ group: SplitGroup) {
        guard let primary = tabs.first(where: { $0.guid == group.primaryTabId }),
              let secondary = tabs.first(where: { $0.guid == group.secondaryTabId }) else {
            return
        }
        let targetCollapsed = primary.aiChatCollapsed && secondary.aiChatCollapsed
        if primary.aiChatCollapsed != targetCollapsed {
            primary.toggleAIChat(targetCollapsed)
        }
        if secondary.aiChatCollapsed != targetCollapsed {
            secondary.toggleAIChat(targetCollapsed)
        }
    }

    /// Reconcile a freshly-created split so it shares exactly one chat tab.
    /// Principle 1: a pane that already has a chat tab keeps it (resolver handles
    /// it; no action needed here). Principle 2: when BOTH panes have a chat tab,
    /// keep the foreground pane's and close the other (a split owns one chat tab).
    @MainActor
    func reconcileSplitChatBinding(_ group: SplitGroup) {
        guard let primary = tabs.first(where: { $0.guid == group.primaryTabId }),
              let secondary = tabs.first(where: { $0.guid == group.secondaryTabId }) else {
            return
        }
        let primaryId = getTabIdentifier(for: primary)
        let secondaryId = getTabIdentifier(for: secondary)
        guard aiChatTabs[primaryId] != nil, aiChatTabs[secondaryId] != nil else {
            return
        }
        let keepSecondary = focusingTab?.guid == secondary.guid
        let dropId = keepSecondary ? primaryId : secondaryId
        closeAIChatTab(for: dropId)
    }

    @MainActor
    func handleSplitVisualsChanged(splitId: String, layout: SplitLayout, ratio: Double) {
        guard let index = splits.firstIndex(where: { $0.id == splitId }) else { return }
        splits[index].layout = layout
        splits[index].ratio = ratio
    }

    @MainActor
    func handleSplitContentsChanged(splitId: String,
                                    primaryTabId: Int,
                                    secondaryTabId: Int) {
        guard let index = splits.firstIndex(where: { $0.id == splitId }) else { return }
        splits[index].primaryTabId = primaryTabId
        splits[index].secondaryTabId = secondaryTabId
        // The accompanying `TabMoved` event lands first via `reorderTabs` →
        // `updateNormalTabs` → `enforceSplitAdjacency`, which runs against
        // the stale primary/secondary on this SplitGroup and undoes the
        // strip reorder Chromium just performed. Re-run `updateNormalTabs`
        // now that the primary/secondary on the group are fresh so
        // `enforceSplitAdjacency` re-applies adjacency in the *new* order.
        // Also covers the bookmark-bound filter that previously gated this
        // call (`splitBookmarkBindings` filtering keys off primary/secondary).
        updateNormalTabs()
    }

    /// Right-click link → "Open link in split view" arrived from Chromium.
    /// The source tab is `partnerTabId`; the linked URL becomes a new pane on
    /// its right. Defers to `openNewTabAsSplit` so the partner pane goes
    /// through the standard pendingSplitPartner marker dance and avoids the
    /// blank-pane bounce. Normalizes the partner first — mirrors the
    /// drag-onto-page and bookmark "Open as Split" flows so a pinned or
    /// bookmark-bound source tab doesn't drag its binding into the split.
    @MainActor
    func handleOpenLinkAsSplitPartner(partnerTabId: Int, url: String) {
        makeTabNormalOpened(tabId: partnerTabId)
        openNewTabAsSplit(partnerTabId: partnerTabId,
                          newTabSlot: .right,
                          partnerNavigateURL: url)
    }

    @MainActor
    func handleSplitRemoved(splitId: String) {
        // A pinned split's underlying Chromium split only dissolves on close
        // (its panes can't be "Remove from Split"-ed). Capture the partner
        // linkage from the still-present live group before dropping it, so the
        // two pinned records survive as one reopenable merged cell instead of
        // splintering into two separate pinned tabs.
        reconcilePinnedSplitPartners()
        splits.removeAll { $0.id == splitId }
        // Drop any split-bookmark bindings that pointed at this split so the
        // bookmark cell stops claiming "opened" and a fresh click re-opens
        // the split. Capture all keys, clear them in a single pass, then
        // emit the per-bookmark sync — otherwise the sidebar relayout
        // triggered by `syncSplitBookmarkOpenedState` observes a partial
        // state where one binding has been cleared and the rest still
        // claim the split is open.
        let clearedBookmarkGuids = splitBookmarkBindings
            .filter { $0.value == splitId }
            .map { $0.key }
        for guid in clearedBookmarkGuids {
            splitBookmarkBindings.removeValue(forKey: guid)
        }
        for guid in clearedBookmarkGuids {
            syncSplitBookmarkOpenedState(bookmarkGuid: guid)
        }
        // Unsplit leaves the two panes alive as standalone tabs — they
        // were hidden from the sidebar list while bound, so refilter now
        // that the binding is gone so they reappear as normal tab rows.
        if !clearedBookmarkGuids.isEmpty {
            updateNormalTabs()
        }
    }

    // MARK: - Mac → Chromium commands

    /// Returns the new split ID on success.
    @discardableResult
    func createSplit(primaryTabId: Int, secondaryTabId: Int, layout: SplitLayout) -> String? {
        ChromiumLauncher.sharedInstance().bridge?.createSplit(
            withTabId: primaryTabId.int64Value,
            secondTabId: secondaryTabId.int64Value,
            layout: layout.rawValue,
            windowId: windowId.int64Value)
    }

    /// Same as `createSplit`, but enforces that `leftTabId` ends up in the
    /// primary (left/top) slot regardless of the tabs' relative tab-strip
    /// indices. Chromium normalizes primary to the lower-indexed tab on
    /// creation; this records the intent so `handleSplitCreated` can issue a
    /// follow-up `reverseTabsInSplit` if needed.
    ///
    /// Always passes the currently focused tab to Chromium as the primary
    /// argument so its internal `ActivateTabAt(primary_idx)` is a no-op.
    /// Activating the other tab takes the focused tab through HIDDEN→VISIBLE,
    /// and `RenderWidgetHostViewCocoa` does not always cleanly resume — the
    /// previously-focused tab's pane then renders blank. `reverseTabsInSplit`
    /// only reorders the strip, never re-activates, so it preserves the
    /// renderer.
    @discardableResult
    func createSplit(leftTabId: Int, rightTabId: Int, layout: SplitLayout) -> String? {
        let primaryArg: Int
        let secondaryArg: Int
        if focusingTab?.guid == leftTabId {
            primaryArg = leftTabId
            secondaryArg = rightTabId
        } else {
            primaryArg = rightTabId
            secondaryArg = leftTabId
        }
        guard let splitId = createSplit(primaryTabId: primaryArg,
                                        secondaryTabId: secondaryArg,
                                        layout: layout) else {
            return nil
        }
        pendingSplitPrimaryByCreateId[splitId] = leftTabId
        return splitId
    }

    func removeSplit(_ splitId: String) {
        ChromiumLauncher.sharedInstance().bridge?.removeSplit(splitId, windowId: windowId.int64Value)
    }

    func updateSplitLayout(_ splitId: String, layout: SplitLayout) {
        ChromiumLauncher.sharedInstance().bridge?.updateSplitLayout(splitId,
                                                                    layout: layout.rawValue,
                                                                    windowId: windowId.int64Value)
    }

    /// Push the new divider position to Chromium. Call on drag-end, not on every
    /// drag frame — Chromium is source of truth and will fan a visualsChanged
    /// notification back so the UI converges on whatever value it accepts.
    func updateSplitRatio(_ splitId: String, ratio: Double) {
        let clamped = max(0.0, min(1.0, ratio))
        ChromiumLauncher.sharedInstance().bridge?.updateSplitRatio(splitId,
                                                                   ratio: clamped,
                                                                   windowId: windowId.int64Value)
    }

    func reverseTabsInSplit(_ splitId: String) {
        ChromiumLauncher.sharedInstance().bridge?.reverseTabs(inSplit: splitId,
                                                              windowId: windowId.int64Value)
    }

    /// Replace one side of a split with another tab from the strip.
    /// - Parameters:
    ///   - slotIndex: 0 = primary, 1 = secondary.
    ///   - swap: true → the evicted tab moves right next to the split and
    ///     joins its tab group, if any (Chromium's `TabsProxy::UpdateSplitTab`
    ///     stages the incoming tab there before the kSwap); false → close the
    ///     evicted tab.
    func swapTabInSplit(_ splitId: String,
                        slotIndex: Int,
                        withTabId otherTabId: Int,
                        swap: Bool) {
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

    /// Pin (or unpin) both panes of a split as a single action.
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
    /// Pin both panes of a split at a specific destination in the pinned
    /// grid. Used by the drag-to-pin path so a dropped split lands next to
    /// whatever the user dropped near, rather than always appended at the
    /// end like `toggleSplitPinStatus` does.
    ///
    /// `atIndex` follows the pinned-grid convention (0 = before all pinned
    /// tabs, `pinnedTabs.count` = at the end). The two panes are pinned in
    /// tab-strip order (primary first, secondary at +1) so adjacency carries
    /// over from the strip into the pinned grid. After both inserts, the
    /// SplitGroup is flagged pinned and the partner relationship is
    /// persisted to match the toggle-pin flow.
    @MainActor
    func pinSplitInsertingAtPinnedIndex(_ splitId: String, atIndex insertionIndex: Int) {
        guard let groupIndex = splits.firstIndex(where: { $0.id == splitId }) else { return }
        let group = splits[groupIndex]
        if group.isPinned { return }

        guard let primaryLive = tabs.first(where: { $0.guid == group.primaryTabId }),
              let secondaryLive = tabs.first(where: { $0.guid == group.secondaryTabId }) else {
            return
        }
        // Skip if either pane is somehow already pinned — would imply a
        // mismatched state we shouldn't double-write.
        if primaryLive.isPinned || secondaryLive.isPinned { return }

        let clampedIndex = max(0, min(insertionIndex, pinnedTabs.count))
        splits[groupIndex].isPinned = true

        // Resolve the anchor against the *current* pinned list, then chain the
        // secondary off the primary's freshly-issued guid. `pinnedTabs` is fed
        // by an async publisher, so referencing `clampedIndex + 1` against it
        // after the first insert traps (the array hasn't grown yet).
        let anchorGuid: String? = clampedIndex > 0
            ? pinnedTabs[clampedIndex - 1].guidInLocalDB
            : nil
        // Detach both panes from any Chromium tab group before pinning.
        // Phi-side pinning bypasses Chromium's `TabStripModel::SetTabPinned`,
        // so the automatic "pinning detaches from group" never fires. The
        // normal-tab pin path handles this explicitly in `moveNormalTab`,
        // but the split path goes straight to the shared `moveNormalTabToPinned`
        // helper and skips it — without this the panes keep their `groupToken`
        // and re-enter the group on unpin.
        if let bridge = ChromiumLauncher.sharedInstance().bridge {
            let groupedPanes = [primaryLive, secondaryLive].filter { $0.groupToken != nil }
            if !groupedPanes.isEmpty {
                bridge.removeTabsFromGroup(withWindowId: windowId.int64Value,
                                            tabIds: groupedPanes.map { NSNumber(value: Int64($0.guid)) })
                for pane in groupedPanes {
                    pane.groupToken = nil
                }
            }
        }
        moveNormalTabToPinned(primaryLive,
                              after: anchorGuid,
                              selectAfterMove: primaryLive.isActive)
        primaryLive.isPinned = true
        moveNormalTabToPinned(secondaryLive,
                              after: primaryLive.guidInLocalDB,
                              selectAfterMove: secondaryLive.isActive)
        secondaryLive.isPinned = true
        updateNormalTabs()

        guard let primaryDB = primaryLive.guidInLocalDB,
              let secondaryDB = secondaryLive.guidInLocalDB else {
            return
        }
        persistPinnedSplitPair(primaryDB: primaryDB, secondaryDB: secondaryDB)
    }

    @MainActor
    func toggleSplitPinStatus(_ splitId: String) {
        guard let index = splits.firstIndex(where: { $0.id == splitId }) else { return }
        if splits[index].isPinned {
            let group = splits[index]
            let primaryGuidInDB = tabs.first(where: { $0.guid == group.primaryTabId })?.guidInLocalDB
            let secondaryGuidInDB = tabs.first(where: { $0.guid == group.secondaryTabId })?.guidInLocalDB
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
        // Pinning: delegate to the chained-anchor path so the secondary
        // pane anchors off the primary's freshly-issued guidInLocalDB.
        // The per-tab toggle path races the async pinnedTabs publisher and
        // can land the secondary before the primary in the DB, which then
        // binds the merged cell's left pane to the secondary tab — closing
        // the cell would only close one pane and strand the other as a
        // pinned placeholder.
        pinSplitInsertingAtPinnedIndex(splitId, atIndex: pinnedTabs.count)
    }

    /// Persist the `splitPartnerGuid` field on two pinned-tab rows and
    /// best-effort patch the in-memory `pinnedTabs` records so the merged
    /// pinned cell can render immediately rather than after the SwiftData
    /// publisher round-trips.
    ///
    /// The in-memory patch silently no-ops when either record hasn't yet
    /// appeared in `pinnedTabs` (e.g. immediately after `moveNormalTabToPinned`,
    /// whose write is async). That is intentional — the publisher delivers
    /// the persisted `splitPartnerGuid` on its next emission and the merged
    /// cell renders correctly from then on. Callers should not rely on the
    /// in-memory patch landing.
    func persistPinnedSplitPair(primaryDB: String, secondaryDB: String) {
        guard !primaryDB.isEmpty, !secondaryDB.isEmpty else { return }
        localStore.updateTabSplitPartner(primaryDB, partnerGuid: secondaryDB)
        localStore.updateTabSplitPartner(secondaryDB, partnerGuid: primaryDB)
        if let primaryPinned = pinnedTabs.first(where: { $0.guidInLocalDB == primaryDB }) {
            primaryPinned.splitPartnerGuid = secondaryDB
        }
        if let secondaryPinned = pinnedTabs.first(where: { $0.guidInLocalDB == secondaryDB }) {
            secondaryPinned.splitPartnerGuid = primaryDB
        }
    }

    /// Stamp the `splitPartnerGuid` linkage onto the in-memory pinned records
    /// of every live `isPinned` split, derived from the live `SplitGroup`
    /// rather than waiting on the async store round-trip.
    ///
    /// `pinSplitInsertingAtPinnedIndex` persists `splitPartnerGuid` to the
    /// store, but the in-memory pinned records only learn it on the next
    /// pinned-tabs publisher emission (`persistPinnedSplitPair`'s in-memory
    /// patch no-ops because the records don't exist yet at pin time). If the
    /// user closes the split before that echo lands, the live group is
    /// removed (`handleSplitRemoved`) while the two pinned records are still
    /// unlinked, and the merged pinned-split cell splinters into two separate
    /// pinned tabs. Reconciling from the live group throughout the split's
    /// life — and once more at the instant it is removed — makes the linkage
    /// durable in memory before the group can disappear.
    ///
    /// Safe to over-call: it only writes when a record's partner actually
    /// changes, and it never runs for a dissolved pinned pair because the
    /// only path that keeps the panes alive while breaking the pair
    /// (`unpinSplitPanesIntoNormalList`) clears the group's `isPinned` flag
    /// first. "Remove from Split" / "Reverse Panes" are not offered for
    /// pinned splits, so a live `isPinned` group always means an intact pair.
    func reconcilePinnedSplitPartners() {
        guard !isIncognito else { return }
        let pinnedByDB: [String: Tab] = Dictionary(
            pinnedTabs.compactMap { tab in tab.guidInLocalDB.map { ($0, tab) } },
            uniquingKeysWith: { first, _ in first }
        )
        for group in splits where group.isPinned {
            guard let primaryLive = tabs.first(where: { $0.guid == group.primaryTabId }),
                  let secondaryLive = tabs.first(where: { $0.guid == group.secondaryTabId }),
                  let primaryDB = primaryLive.guidInLocalDB, !primaryDB.isEmpty,
                  let secondaryDB = secondaryLive.guidInLocalDB, !secondaryDB.isEmpty,
                  let primaryPinned = pinnedByDB[primaryDB],
                  let secondaryPinned = pinnedByDB[secondaryDB] else {
                continue
            }
            if primaryPinned.splitPartnerGuid != secondaryDB {
                primaryPinned.splitPartnerGuid = secondaryDB
                localStore.updateTabSplitPartner(primaryDB, partnerGuid: secondaryDB)
            }
            if secondaryPinned.splitPartnerGuid != primaryDB {
                secondaryPinned.splitPartnerGuid = primaryDB
                localStore.updateTabSplitPartner(secondaryDB, partnerGuid: primaryDB)
            }
        }
    }

    // MARK: - Pinned-split restoration

    /// Open both panes of a persisted pinned split. Used when the user clicks
    /// the merged-cell representation of a pinned split that was restored
    /// from disk: at least one (and possibly both) of the underlying Chromium
    /// tabs may be closed, so we issue `createTab` for whichever halves are
    /// missing. Once both reach `handleNewTabFromChromium`, the pinned-tab
    /// auto-bind path calls `maybeRecreatePersistedPinnedSplit` which then
    /// creates the `SplitGroup`.
    ///
    /// - Parameter focusRight: when true, the right pane becomes the focused
    ///   tab once both panes are open (the user clicked closer to the right
    ///   favicon); otherwise focus lands on the left pane.
    @MainActor
    func openPinnedSplit(leftPinnedGuid: String, rightPinnedGuid: String, focusRight: Bool) {
        guard let leftPinned = pinnedTabs.first(where: { $0.guidInLocalDB == leftPinnedGuid }),
              let rightPinned = pinnedTabs.first(where: { $0.guidInLocalDB == rightPinnedGuid }) else {
            return
        }
        let leftLive = tabs.first(where: { $0.guidInLocalDB == leftPinnedGuid })
        let rightLive = tabs.first(where: { $0.guidInLocalDB == rightPinnedGuid })

        let leftOpen = leftLive?.webContentWrapper != nil
        let rightOpen = rightLive?.webContentWrapper != nil

        // Fast path: both already live. If a `SplitGroup` already covers the
        // pair (Chromium auto-restored it, or the user re-clicked the cell
        // while both were still open) just activate the preferred pane.
        if leftOpen, rightOpen {
            let preferred = focusRight ? rightLive : leftLive
            preferred?.webContentWrapper?.setAsActiveTab()
            if let leftGuid = leftLive?.guid,
               splitGroup(forTabId: leftGuid) == nil {
                pendingPinnedSplitRecreateGuids.insert(leftPinnedGuid)
                pendingPinnedSplitRecreateGuids.insert(rightPinnedGuid)
                tryRecreatePendingPinnedSplit(leftDBGuid: leftPinnedGuid,
                                              rightDBGuid: rightPinnedGuid)
            }
            return
        }

        // Mark both halves as awaiting recreation so the next-arriving tabs
        // know to trigger `createSplit`. Without this gate, Chromium's own
        // session-restore path could also reach `handleNewTabFromChromium`
        // for these guids and race against our `createSplit`.
        pendingPinnedSplitRecreateGuids.insert(leftPinnedGuid)
        pendingPinnedSplitRecreateGuids.insert(rightPinnedGuid)

        if !leftOpen {
            createTab(leftPinned.url ?? "",
                      customGuid: leftPinnedGuid,
                      focusAfterCreate: !focusRight)
        }
        if !rightOpen {
            createTab(rightPinned.url ?? "",
                      customGuid: rightPinnedGuid,
                      focusAfterCreate: focusRight)
        }
    }

    /// When a pinned tab just bound to a live Chromium tab, check whether its
    /// partner is also live, the pair was explicitly requested via
    /// `openPinnedSplit`, and no `SplitGroup` covers it yet. If so, schedule
    /// a `createSplit` on the next run-loop tick so it does not re-enter the
    /// new-tab event flow.
    func maybeRecreatePersistedPinnedSplit(forJustOpenedPinnedTab pinnedTab: Tab) {
        guard let partnerDBGuid = pinnedTab.splitPartnerGuid, !partnerDBGuid.isEmpty,
              let myDBGuid = pinnedTab.guidInLocalDB else {
            return
        }
        guard pendingPinnedSplitRecreateGuids.contains(myDBGuid),
              pendingPinnedSplitRecreateGuids.contains(partnerDBGuid) else {
            return
        }
        // Order by pinned-grid position so the just-opened tab is mapped to
        // its actual left/right role. This handler fires for whichever pane
        // arrives second; passing `myDBGuid` blindly as `leftDBGuid` would
        // swap the panes when the right pane is the late arrival, which
        // `createSplit(leftTabId:rightTabId:)` would then register as a
        // reversed primary and `handleSplitCreated` would reorder the strip.
        let myIdx = pinnedTabs.firstIndex(where: { $0.guidInLocalDB == myDBGuid })
        let partnerIdx = pinnedTabs.firstIndex(where: { $0.guidInLocalDB == partnerDBGuid })
        let (leftDBGuid, rightDBGuid): (String, String)
        if let myIdx, let partnerIdx, partnerIdx < myIdx {
            (leftDBGuid, rightDBGuid) = (partnerDBGuid, myDBGuid)
        } else {
            (leftDBGuid, rightDBGuid) = (myDBGuid, partnerDBGuid)
        }
        tryRecreatePendingPinnedSplit(leftDBGuid: leftDBGuid, rightDBGuid: rightDBGuid)
    }

    /// Validate both halves are live and ungrouped, then schedule a deferred
    /// `createSplit`. Pending markers are cleared up front so the deferred
    /// task is the only attempt; if Chromium rejects the split we don't keep
    /// retrying.
    private func tryRecreatePendingPinnedSplit(leftDBGuid: String, rightDBGuid: String) {
        guard let leftLive = tabs.first(where: { $0.guidInLocalDB == leftDBGuid }),
              let rightLive = tabs.first(where: { $0.guidInLocalDB == rightDBGuid }),
              leftLive.webContentWrapper != nil,
              rightLive.webContentWrapper != nil else {
            return
        }
        if splitGroup(forTabId: leftLive.guid) != nil ||
           splitGroup(forTabId: rightLive.guid) != nil {
            pendingPinnedSplitRecreateGuids.remove(leftDBGuid)
            pendingPinnedSplitRecreateGuids.remove(rightDBGuid)
            return
        }

        // A previous click already queued the async `createSplit` for this
        // pair. Without this guard, a rapid double click on the merged cell
        // would queue a second async block and `createSplit` would fire twice
        // (the first one likely succeeds, the second's guard at the head of
        // the block catches it, but the two requests racing against Chromium
        // is brittle — earlier rejection avoids the race entirely).
        if pinnedSplitRecreateInFlight.contains(leftDBGuid) ||
           pinnedSplitRecreateInFlight.contains(rightDBGuid) {
            return
        }

        pendingPinnedSplitRecreateGuids.remove(leftDBGuid)
        pendingPinnedSplitRecreateGuids.remove(rightDBGuid)
        pinnedSplitRecreateInFlight.insert(leftDBGuid)
        pinnedSplitRecreateInFlight.insert(rightDBGuid)
        let leftTabId = leftLive.guid
        let rightTabId = rightLive.guid
        // Defer to the next runloop so the surrounding new-tab event finishes
        // unwinding before we reach back into Chromium. Calling `createSplit`
        // synchronously inside `handleNewTabFromChromium` can crash because
        // Chromium is still finalizing tab-strip state for the arriving tab.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer {
                self.pinnedSplitRecreateInFlight.remove(leftDBGuid)
                self.pinnedSplitRecreateInFlight.remove(rightDBGuid)
            }
            // Bail if either pane has been unbound from its pinned DB guid
            // by the time this deferred block runs — e.g. the user dragged
            // the pinned split out to the normal tab list or to a bookmark
            // before the recreate fired. Without this guard the deferred
            // fires `createSplit` on now-unbound tabs and either duplicates
            // an explicit `createSplit` already issued by the drag-out path
            // (racing against Chromium's echo of the first one) or attaches
            // a stray pinned-style split to tabs the user just freed.
            guard let leftLiveCheck = self.tabs.first(where: { $0.guid == leftTabId }),
                  let rightLiveCheck = self.tabs.first(where: { $0.guid == rightTabId }),
                  leftLiveCheck.webContentWrapper != nil,
                  rightLiveCheck.webContentWrapper != nil,
                  leftLiveCheck.guidInLocalDB == leftDBGuid,
                  rightLiveCheck.guidInLocalDB == rightDBGuid else {
                return
            }
            if self.splitGroup(forTabId: leftTabId) != nil ||
               self.splitGroup(forTabId: rightTabId) != nil {
                return
            }
            self.createSplit(leftTabId: leftTabId,
                             rightTabId: rightTabId,
                             layout: .vertical)
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
        // the two panes together once the new tab arrives.
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
            tab.guidInLocalDB = nil
            tab.webContentWrapper?.updateTabCustomValue("")
            syncAllBookmarksOpenedState()
        }
    }

    /// Forms a vertical split between a bookmark and `partnerTabId`. If the
    /// bookmark currently has an attached live tab that is distinct from
    /// the partner and not already in a split, detaches that tab from the
    /// bookmark binding and uses it as the new pane directly — the user
    /// keeps the open page instead of getting a fresh duplicate. Otherwise
    /// opens a new tab on the bookmark URL via `openNewTabAsSplit`. Shared
    /// by the drag-onto-page flow, the bookmark "Open as Split" menu, and
    /// any future entry point so all three behave identically.
    /// - Returns: `true` when a split was attempted, `false` when the
    ///   bookmark could not be resolved (deleted mid-action, folder, or
    ///   empty URL). The caller may fall back to other entry points.
    @discardableResult
    func formSplitFromBookmark(bookmarkGuid: String,
                               partnerTabId: Int,
                               newTabSlot: SplitSlot) -> Bool {
        guard let bookmark = bookmarkManager.bookmark(withGuid: bookmarkGuid),
              !bookmark.isFolder,
              let url = bookmark.url, !url.isEmpty else { return false }
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
            switch newTabSlot {
            case .left:
                createSplit(leftTabId: attachedLiveTab.guid,
                            rightTabId: partnerTabId,
                            layout: .vertical)
            case .right:
                createSplit(leftTabId: partnerTabId,
                            rightTabId: attachedLiveTab.guid,
                            layout: .vertical)
            }
            return true
        }
        // Attached-and-IS-partner: the partner tab was the bookmark's live
        // representation and is now detached above. Opening another tab on
        // the same URL would just duplicate the partner pane's content, so
        // use a blank NTP partner instead. The detached (formerly
        // attached) partner keeps the dropped slot; the new NTP takes the
        // opposite side.
        if attachedLiveTab?.guid == partnerTabId {
            let oppositeSlot: SplitSlot = (newTabSlot == .left) ? .right : .left
            openNewTabAsSplit(partnerTabId: partnerTabId, newTabSlot: oppositeSlot)
            return true
        }
        // Bookmark has no live representation: materialize a fresh unbound
        // tab on the bookmark URL as the new pane.
        openNewTabAsSplit(partnerTabId: partnerTabId,
                          newTabSlot: newTabSlot,
                          partnerNavigateURL: URLProcessor.processUserInput(url))
        return true
    }

    /// Opens a fresh tab (on `partnerNavigateURL` when given, else a
    /// new-tab page) and, once Chromium echoes it back, pairs it with
    /// `partnerTabId` into a vertical split.
    /// - Parameters:
    ///   - newTabSlot: Where the new tab should end up. Defaults to `.right`
    ///     (right-click "Open as Split" — right-clicked tab stays on the
    ///     left, new tab opens on the right). Pass `.left` to drop the new
    ///     tab on the left and leave the partner on the right.
    ///   - partnerNavigateURL: When non-nil, the new pane is created directly
    ///     on this URL instead of landing on a new-tab page first, so the
    ///     NTP never flashes before the real page. Used by the
    ///     open-link-as-split and split-bookmark paths.
    ///   - boundBookmarkGuid: When non-nil, the resulting split's id is
    ///     registered in `splitBookmarkBindings` under this bookmark guid so
    ///     a subsequent click on the bookmark activates the existing split.
    func openNewTabAsSplit(partnerTabId: Int,
                           newTabSlot: SplitSlot = .right,
                           partnerNavigateURL: String? = nil,
                           boundBookmarkGuid: String? = nil,
                           insertionIndex: Int? = nil) {
        guard splitGroup(forTabId: partnerTabId) == nil else { return }
        // Splits never live in the pinned strip. If the partner is currently
        // pinned, demote it to the normal list first and leave a fresh
        // unopened pinned placeholder pointing at the same URL at the
        // original pinned slot, so the user sees the pinned entry stay put
        // while the live tab participates in the new split below.
        demotePinnedTabLeavingPlaceholder(forTabId: partnerTabId)
        let pendingGuid = SplitPendingGuid.partner.mint()
        pendingSplitPartnerByCustomGuid[pendingGuid] = PendingSplitPartner(
            partnerTabId: partnerTabId,
            newTabSlot: newTabSlot,
            boundBookmarkGuid: boundBookmarkGuid,
            insertionIndex: insertionIndex
        )
        // Mark the partner BEFORE `createTab`. Chromium's active-tab handler
        // runs synchronously inside the new-tab creation and would otherwise
        // drive the existing partner through OCCLUDED → pending-hide → HIDDEN.
        // The mark suppresses that bounce so the partner's
        // `RenderWidgetHostViewCocoa` never has to attempt a HIDDEN → VISIBLE
        // resume — the root cause of the blank-pane symptom. Cleared in
        // `consumePendingSplitPartner` and (idempotently) by Chromium's
        // `CreateSplit` once the split is established.
        ChromiumLauncher.sharedInstance().bridge?
            .markPendingSplitPartner(withTabId: partnerTabId.int64Value,
                                     windowId: windowId.int64Value)
        // Create the pane directly on the target URL when one was supplied —
        // parking it on NTP and navigating after the echo flashes the
        // new-tab page first. The initial load of a fresh tab cannot trip
        // CrossDomainNewTabNavigationThrottle even though the customGuid
        // marker is still set: a brand-new WebContents has no committed URL
        // and the load has no initiator origin, so the throttle's source-URL
        // check never passes.
        let createURL =
            (partnerNavigateURL?.isEmpty == false) ? partnerNavigateURL! : "chrome://newtab"
        createTab(createURL, customGuid: pendingGuid, focusAfterCreate: true)
        // Timeout cleanup: if the new tab never arrives (Chromium failure,
        // partner closed mid-flight, etc.), drop the pending record and clear
        // the visibility-skip mark so the partner can hide normally again.
        let partnerId = partnerTabId
        let wid = windowId
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            guard self.pendingSplitPartnerByCustomGuid[pendingGuid] != nil else {
                return  // already consumed
            }
            self.pendingSplitPartnerByCustomGuid.removeValue(forKey: pendingGuid)
            ChromiumLauncher.sharedInstance().bridge?
                .clearPendingSplitPartner(withTabId: partnerId.int64Value,
                                          windowId: wid.int64Value)
        }
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
    /// pending split request keyed by its customGuid, create the split now.
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
        // on the partner — Chromium's `CreateSplit` clears it idempotently on
        // success, but the early-return guards below would otherwise leave a
        // permanent skip latched on the partner tab.
        let clearPartnerMark: () -> Void = { [weak self] in
            guard let self else { return }
            ChromiumLauncher.sharedInstance().bridge?
                .clearPendingSplitPartner(withTabId: pending.partnerTabId.int64Value,
                                          windowId: self.windowId.int64Value)
        }
        guard pending.partnerTabId != tab.guid,
              splitGroup(forTabId: pending.partnerTabId) == nil else {
            clearPartnerMark()
            return
        }
        // Sync Mac's focus to the new tab before `createSplit` decides which
        // side to pass Chromium as the primary pane. The new tab was created
        // with `focusAfterCreate: true`, so Chromium has already activated it,
        // but Chromium's `activeTabChanged` event may not have reached Mac yet
        // — `focusingTab` would still point at the partner. The `createSplit`
        // heuristic would then hand Chromium the partner as primary, and
        // Chromium's split-creation `ActivateTabAt` would yank focus back to
        // the partner, leaving the new pane focus-ringed but Mac's state
        // (sidebar selection, address-bar routing) stuck on the partner.
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
        // `focuseTab` call below — this flow arrives via EventBus's
        // `Task { @MainActor in ... }` dispatch, so `assumeIsolated` is safe.
        if let partnerToken = tabs.first(where: { $0.guid == pending.partnerTabId })?.groupToken {
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
                         to: pending.partnerTabId,
                         on: pending.newTabSlot)
        let createdSplitId: String?
        switch pending.newTabSlot {
        case .right:
            createdSplitId = createSplit(leftTabId: pending.partnerTabId,
                                         rightTabId: tab.guid,
                                         layout: .vertical)
        case .left:
            createdSplitId = createSplit(leftTabId: tab.guid,
                                         rightTabId: pending.partnerTabId,
                                         layout: .vertical)
        }
        // Closed-split drop: both panes were just materialized here, so they
        // sit at the tail of the strip. Record the requested drop index
        // against the new split id; `handleSplitCreated` relocates the pair
        // once Chromium echoes the split back.
        if let insertionIndex = pending.insertionIndex,
           let splitId = createdSplitId {
            pendingSplitMoveToNormalIndexByCreateId[splitId] = insertionIndex
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
            clearPartnerMark()
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
        guard let group = splitGroup(forId: splitId) else { return true }
        let evictedTabId = slotIndex == 0 ? group.primaryTabId : group.secondaryTabId
        return tabs.first(where: { $0.guid == evictedTabId })?.isNTP != true
    }

    /// Opens a fresh tab directly on `url` and, once Chromium echoes it back,
    /// swaps it into the given split slot via `swapTabInSplit(..., swap: true)`
    /// so the evicted pane lands right next to the split. Used by the
    /// drag-onto-split-pane flow for the bookmark and closed-pinned sources,
    /// which have no live tab id to swap directly. Creating the tab on `url`
    /// (instead of NTP plus a deferred navigate) is throttle-safe — see the
    /// initial-load note in `openNewTabAsSplit`.
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
        guard splitGroup(forId: pending.splitId) != nil else { return }
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
        // load, see the note in `openNewTabAsSplit`.
        createTab(url, customGuid: pendingGuid, focusAfterCreate: true)
        schedulePendingPrimarySplitCleanup(pendingGuid: pendingGuid)
    }

    /// Opens two URLs as a side-by-side split. The first becomes the primary
    /// (left) pane and the second becomes the partner (right) pane. Used by
    /// the split-view bookmark click flow — both URLs are stored on a single
    /// `Bookmark`, and opening it restores the original pair.
    /// - Parameter bookmarkGuid: When non-nil, both panes are rebound to
    ///   this bookmark guid once they finish navigating, so the bookmark
    ///   tracks the open split and a subsequent click activates the existing
    ///   pair instead of opening another one.
    func openTwoURLsAsSplit(primaryURL: String,
                            secondaryURL: String,
                            bookmarkGuid: String? = nil,
                            groupToken: String? = nil,
                            insertionIndex: Int? = nil) {
        let pendingGuid = SplitPendingGuid.primary.mint()
        pendingPrimarySplitTargetByGuid[pendingGuid] = PendingPrimarySplit(
            secondaryURL: secondaryURL,
            boundBookmarkGuid: bookmarkGuid,
            groupToken: groupToken,
            insertionIndex: insertionIndex
        )
        createTab(primaryURL, customGuid: pendingGuid, focusAfterCreate: true)
        schedulePendingPrimarySplitCleanup(pendingGuid: pendingGuid)
    }

    /// Timeout cleanup shared by the two primary-split openers: if the new
    /// tab never arrives, drop the pending record so it can't fire a stale
    /// split later. Mirrors the 5s cleanup in `openNewTabAsSplit` and
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
        openNewTabAsSplit(partnerTabId: tab.guid,
                          newTabSlot: .right,
                          partnerNavigateURL: pending.secondaryURL,
                          boundBookmarkGuid: pending.boundBookmarkGuid,
                          insertionIndex: pending.insertionIndex)
    }

}

/// Which pane a tab occupies in a vertical split, expressed in user-facing
/// left/right terms rather than Chromium's primary/secondary terms.
enum SplitSlot {
    /// Primary slot (top for `.horizontal`, left for `.vertical`).
    case left
    /// Secondary slot (bottom for `.horizontal`, right for `.vertical`).
    case right
}

/// Stored alongside a pending new-tab request so `consumePendingSplitPartner`
/// can pair the arriving tab with the right partner on the right side.
struct PendingSplitPartner {
    /// The existing tab the new tab will be paired with.
    let partnerTabId: Int
    /// Which slot the new tab should take in the resulting split.
    let newTabSlot: SplitSlot
    /// Optional bookmark guid to rebind to the new pane after the throttle
    /// marker is cleared. Used by the split-bookmark open flow so the
    /// bookmark cell stays in sync with the open split.
    var boundBookmarkGuid: String? = nil
    /// Optional destination index (in `normalTabs` space) for the finished
    /// split. Non-nil when a closed split was dropped into the tab list at a
    /// specific spot; `consumePendingSplitPartner` forwards it so
    /// `handleSplitCreated` can relocate the pair off the strip's end.
    var insertionIndex: Int? = nil
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
}
