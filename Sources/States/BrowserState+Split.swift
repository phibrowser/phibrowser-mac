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
/// They masquerade as `guidInLocalDB` from creation until the consumer in
/// `handleNewTabFromChromium` clears them on both Swift and Chromium sides.
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

    private static let partnerPrefix = "split-pending:"
    private static let primaryPrefix = "split-primary-pending:"

    private var prefix: String {
        switch self {
        case .partner: return Self.partnerPrefix
        case .primary: return Self.primaryPrefix
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
    func unpinClosedPinnedSplit(leftDB: String, rightDB: String) {
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
        openTwoURLsAsSplit(primaryURL: leftURL, secondaryURL: rightURL)
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
    func snapDropOutsideSplitPair(toIndex: Int, fromIndex: Int) -> Int {
        for group in splits {
            guard let primaryIdx = normalTabs.firstIndex(where: { $0.guid == group.primaryTabId }),
                  let secondaryIdx = normalTabs.firstIndex(where: { $0.guid == group.secondaryTabId }) else {
                continue
            }
            let lo = min(primaryIdx, secondaryIdx)
            let hi = max(primaryIdx, secondaryIdx)
            guard hi == lo + 1, toIndex == lo + 1 else { continue }
            return fromIndex <= lo ? hi + 1 : lo
        }
        return toIndex
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
    /// state (the foreground pane's), so switching the active pane does not
    /// toggle the sidebar between collapsed and expanded.
    @MainActor
    func syncSplitAIChatCollapsed(_ group: SplitGroup) {
        guard let primary = tabs.first(where: { $0.guid == group.primaryTabId }),
              let secondary = tabs.first(where: { $0.guid == group.secondaryTabId }) else {
            return
        }
        let (source, target) = focusingTab?.guid == secondary.guid
            ? (secondary, primary)
            : (primary, secondary)
        if target.aiChatCollapsed != source.aiChatCollapsed {
            target.toggleAIChat(source.aiChatCollapsed)
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
    /// blank-pane bounce.
    @MainActor
    func handleOpenLinkAsSplitPartner(partnerTabId: Int, url: String) {
        openNewTabAsSplit(partnerTabId: partnerTabId,
                          newTabSlot: .right,
                          partnerNavigateURL: url)
    }

    @MainActor
    func handleSplitRemoved(splitId: String) {
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
    ///   - swap: true → swap positions; false → close the evicted tab.
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
        let group = splits[index]
        let primaryId = group.primaryTabId
        let secondaryId = group.secondaryTabId
        let primaryGuidInDB = tabs.first(where: { $0.guid == primaryId })?.guidInLocalDB
        let secondaryGuidInDB = tabs.first(where: { $0.guid == secondaryId })?.guidInLocalDB

        let willPin = !splits[index].isPinned
        splits[index].isPinned.toggle()

        toggleTabPinStatus(primaryId, guidInDB: primaryGuidInDB)
        toggleTabPinStatus(secondaryId, guidInDB: secondaryGuidInDB)

        guard willPin else { return }
        // After pinning, each live tab now carries a freshly-issued
        // guidInLocalDB. Capture both and persist the partner relationship so
        // the pinned-split rendering can be reconstructed after a restart.
        guard let primaryDB = tabs.first(where: { $0.guid == primaryId })?.guidInLocalDB,
              let secondaryDB = tabs.first(where: { $0.guid == secondaryId })?.guidInLocalDB else {
            return
        }
        persistPinnedSplitPair(primaryDB: primaryDB, secondaryDB: secondaryDB)
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
        tryRecreatePendingPinnedSplit(leftDBGuid: myDBGuid, rightDBGuid: partnerDBGuid)
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

    /// Opens a fresh new-tab-page tab and, once Chromium echoes it back,
    /// pairs it with `partnerTabId` into a vertical split.
    /// - Parameters:
    ///   - newTabSlot: Where the new tab should end up. Defaults to `.right`
    ///     (right-click "Open as Split" — right-clicked tab stays on the
    ///     left, new tab opens on the right). Pass `.left` to drop the new
    ///     tab on the left and leave the partner on the right.
    ///   - partnerNavigateURL: When non-nil, the new pane is navigated to
    ///     this URL after the customGuid marker is cleared. Used by the
    ///     split-bookmark open path so the second pane lands on its saved
    ///     URL instead of remaining a new-tab page.
    ///   - boundBookmarkGuid: When non-nil, the resulting split's id is
    ///     registered in `splitBookmarkBindings` under this bookmark guid so
    ///     a subsequent click on the bookmark activates the existing split.
    func openNewTabAsSplit(partnerTabId: Int,
                           newTabSlot: SplitSlot = .right,
                           partnerNavigateURL: String? = nil,
                           boundBookmarkGuid: String? = nil) {
        guard splitGroup(forTabId: partnerTabId) == nil else { return }
        let pendingGuid = SplitPendingGuid.partner.mint()
        pendingSplitPartnerByCustomGuid[pendingGuid] = PendingSplitPartner(
            partnerTabId: partnerTabId,
            newTabSlot: newTabSlot,
            navigateURL: partnerNavigateURL,
            boundBookmarkGuid: boundBookmarkGuid
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
        createTab("chrome://newtab", customGuid: pendingGuid, focusAfterCreate: true)
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

    /// Called from `handleNewTabFromChromium`. If the arriving tab matches a
    /// pending split request keyed by its customGuid, create the split now.
    func consumePendingSplitPartner(for tab: Tab) {
        guard let customGuid = tab.guidInLocalDB,
              SplitPendingGuid.partner.matches(customGuid),
              let pending = pendingSplitPartnerByCustomGuid.removeValue(forKey: customGuid) else {
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
        // Drop the transient pairing marker on both sides. On Swift it keeps
        // `isPinnedOrInDB` from latching true; on Chromium it stops
        // CrossDomainNewTabNavigationThrottle from treating the pane as a
        // pinned/bookmark tab and redirecting cross-domain typing into a fresh
        // tab. Without the bridge call the throttle still fires even after
        // `guidInLocalDB` is cleared.
        tab.guidInLocalDB = nil
        tab.webContentWrapper?.updateTabCustomValue("")
        // For split-bookmark opens the new pane needs to land on the saved
        // secondary URL rather than staying on NTP. The throttle-avoidance
        // marker is already cleared above, so the navigation is safe here.
        if let navigateURL = pending.navigateURL, !navigateURL.isEmpty {
            tab.webContentWrapper?.navigate(toURL: navigateURL)
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

    // MARK: - Open-URL-as-split (bookmark "Open as Split")

    /// Opens `url` as a new tab and, once Chromium echoes it back, creates a
    /// fresh new-tab-page partner and splits the pair. The arriving URL tab
    /// is the primary (left) pane; the NTP is the secondary (right) pane.
    /// Used by the bookmark "Open as Split" menu.
    func openURLAsSplit(url: String) {
        let pendingGuid = SplitPendingGuid.primary.mint()
        // Mirror the throttle-avoidance trick in `openNewTabAsSplit`: open
        // the tab as NTP with the marker, then navigate to `url` once the
        // marker is cleared in the consumer.
        pendingPrimarySplitTargetByGuid[pendingGuid] = PendingPrimarySplit(
            primaryURL: url,
            secondaryURL: nil
        )
        createTab("chrome://newtab", customGuid: pendingGuid, focusAfterCreate: true)
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
                            bookmarkGuid: String? = nil) {
        let pendingGuid = SplitPendingGuid.primary.mint()
        pendingPrimarySplitTargetByGuid[pendingGuid] = PendingPrimarySplit(
            primaryURL: primaryURL,
            secondaryURL: secondaryURL,
            boundBookmarkGuid: bookmarkGuid
        )
        createTab("chrome://newtab", customGuid: pendingGuid, focusAfterCreate: true)
    }

    /// Called from `handleNewTabFromChromium`. If the arriving tab is marked
    /// as a pending-primary split, kick off the NTP partner that completes
    /// the pair through the regular `openNewTabAsSplit` path. When the
    /// pending record carries a `secondaryURL` (split-bookmark open), pass
    /// it through so the partner navigates to that URL instead of staying
    /// on NTP.
    func consumePendingPrimarySplit(for tab: Tab) {
        guard let customGuid = tab.guidInLocalDB,
              SplitPendingGuid.primary.matches(customGuid),
              let pending = pendingPrimarySplitTargetByGuid.removeValue(forKey: customGuid) else {
            return
        }
        // Same cleanup as `consumePendingSplitPartner`: drop the transient
        // marker on both sides so it doesn't latch a pinned/bookmark binding
        // or trigger CrossDomainNewTabNavigationThrottle.
        tab.guidInLocalDB = nil
        tab.webContentWrapper?.updateTabCustomValue("")
        tab.webContentWrapper?.navigate(toURL: pending.primaryURL)
        openNewTabAsSplit(partnerTabId: tab.guid,
                          newTabSlot: .right,
                          partnerNavigateURL: pending.secondaryURL,
                          boundBookmarkGuid: pending.boundBookmarkGuid)
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
    /// Optional URL to navigate the new pane to once its throttle marker is
    /// cleared. Nil leaves the pane as a new-tab page (the historical
    /// behavior for the right-click "Open as Split" menu).
    var navigateURL: String? = nil
    /// Optional bookmark guid to rebind to the new pane after the throttle
    /// marker is cleared. Used by the split-bookmark open flow so the
    /// bookmark cell stays in sync with the open split.
    var boundBookmarkGuid: String? = nil
}

/// Stored alongside a pending "open URL as primary pane" request. The
/// primary URL is always present; `secondaryURL` is non-nil when the caller
/// wants the partner pane navigated to a specific URL (split-bookmark open)
/// rather than left blank.
struct PendingPrimarySplit {
    let primaryURL: String
    let secondaryURL: String?
    /// Optional bookmark guid to rebind to both panes once they settle, so
    /// the originating split bookmark tracks the open split.
    var boundBookmarkGuid: String? = nil
}
