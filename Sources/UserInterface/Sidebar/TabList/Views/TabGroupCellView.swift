// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import QuartzCore
import SnapKit
import SwiftUI

/// Owner-side hooks for a `TabGroupCellView`. Cell-side instances
/// dispatch height changes and inner-row interactions through this
/// protocol; the controller (`SidebarTabListViewController`) routes them
/// to the outer `NSOutlineView` and the existing tab-cell handling
/// pipeline.
protocol TabGroupCellViewDelegate: AnyObject {
    /// Cell's desired height changed (collapse toggle or member-count
    /// shift). Controller forwards to
    /// `outlineView.noteHeightOfRowsWithIndexesChanged(_)`, using the
    /// caller's animation policy.
    func tabGroupCellNeedsHeightUpdate(
        _ cell: TabGroupCellView,
        for token: String,
        animated: Bool
    )

    /// Inner table's chevron requested a collapse toggle. Controller
    /// dispatches to the bridge (mirrors the existing user-gesture
    /// path).
    func tabGroupCellDidToggleCollapse(_ cell: TabGroupCellView,
                                       group: WebContentGroupInfo)

    func tabGroupCellDidRequestCloseGroup(_ cell: TabGroupCellView,
                                          group: WebContentGroupInfo)

    func tabGroupCellDidRequestOverview(_ cell: TabGroupCellView,
                                        group: WebContentGroupInfo)

    func tabGroupCell(_ cell: TabGroupCellView,
                      beginDraggingGroup group: WebContentGroupInfo,
                      from headerView: NSView,
                      mouseDownEvent: NSEvent)

    /// Inner-table tab cell requested a close. Mirrors the route used
    /// by ungrouped tab cells via `TabCellDelegate`.
    func tabGroupCell(_ cell: TabGroupCellView,
                      tabDidRequestClose tab: Tab)

    func tabGroupCell(_ cell: TabGroupCellView,
                      didRequestMultiSelectionFor tab: Tab,
                      modifierFlags: NSEvent.ModifierFlags) -> Bool

    func tabGroupCell(_ cell: TabGroupCellView,
                      didRequestMultiSelectionFor splitPair: SplitPairSidebarItem,
                      modifierFlags: NSEvent.ModifierFlags) -> Bool

    /// Inner table detected a grouped-tab row drag. The controller owns
    /// the outer outline view, so it starts the AppKit drag session from
    /// that boundary while the cell supplies the row view snapshot.
    /// `rowView` is `SidebarTabCellView` for normal grouped tabs and
    /// `SidebarSplitPairCellView` for the merged in-group split row —
    /// the latter drags the whole pair via the left pane's guid, which
    /// downstream handlers already treat as a split.
    func tabGroupCell(_ cell: TabGroupCellView,
                      beginDragging tab: Tab,
                      from rowView: SidebarCellView,
                      mouseDownEvent: NSEvent)

    /// A drag started from the inner table for a grouped tab. Mirrors
    /// `outlineView(_:draggingSession:willBeginAt:forItems:)` so the
    /// outer `BrowserState.tabDraggingSession` and `isDraggingTab`
    /// state stay aligned with ungrouped-tab drags.
    func tabGroupCell(_ cell: TabGroupCellView,
                      draggingSessionWillBegin session: NSDraggingSession,
                      at screenPoint: NSPoint,
                      for tab: Tab)

    /// Inner-table drag finished (committed or cancelled). Mirrors
    /// `outlineView(_:draggingSession:endedAt:operation:)`.
    func tabGroupCell(_ cell: TabGroupCellView,
                      draggingSessionEnded session: NSDraggingSession,
                      at screenPoint: NSPoint,
                      operation: NSDragOperation)

    /// Drop landed in the inner table at `normalTabsIdx`. Controller
    /// performs the same `moveNormalTabLocally` + `addTabsToGroup` /
    /// `removeTabsFromGroup` choreography the outer outline runs for
    /// drops on tab-group rows. Returns `true` when the drop committed.
    func tabGroupCell(_ cell: TabGroupCellView,
                      didAcceptTab tab: Tab,
                      intoGroupToken token: String,
                      atNormalTabsIdx normalTabsIdx: Int) -> Bool

    /// Drop landed in the inner table for a temporary multi-selection.
    /// Controller owns the selected-id reorder and group-membership batch.
    func tabGroupCell(_ cell: TabGroupCellView,
                      didAcceptTabsWithGuids tabIds: [Int],
                      intoGroupToken token: String,
                      atNormalTabsIdx normalTabsIdx: Int) -> Bool

    /// Inner table can accept bookmarks that can become group members.
    /// The controller owns bookmark lookup, so validation stays routed
    /// through this boundary before the cell shows a drop indicator.
    func tabGroupCell(_ cell: TabGroupCellView,
                      canAcceptBookmarkWithGuid guid: String) -> Bool

    /// Inner table can accept a bookmark multi-selection batch.
    func tabGroupCell(_ cell: TabGroupCellView,
                      canAcceptBookmarksWithGuids guids: [String]) -> Bool

    /// Inner table can accept pinned tabs that can become group members.
    func tabGroupCell(_ cell: TabGroupCellView,
                      canAcceptPinnedTabWithGuid pinnedGuid: String) -> Bool

    /// Drop landed in the inner table for a pinned tab. The controller
    /// converts it to a normal group member and removes the pinned record.
    func tabGroupCell(_ cell: TabGroupCellView,
                      didAcceptPinnedTabWithGuid pinnedGuid: String,
                      intoGroupToken token: String,
                      atNormalTabsIdx normalTabsIdx: Int,
                      groupIndex: Int) -> Bool

    /// Drop landed in the inner table for a bookmark. The controller
    /// converts it to a normal group member and removes the bookmark.
    func tabGroupCell(_ cell: TabGroupCellView,
                      didAcceptBookmarkWithGuid bookmarkGuid: String,
                      intoGroupToken token: String,
                      atNormalTabsIdx normalTabsIdx: Int,
                      groupIndex: Int) -> Bool

    /// Drop landed in the inner table for a bookmark multi-selection batch.
    func tabGroupCell(_ cell: TabGroupCellView,
                      didAcceptBookmarksWithGuids bookmarkGuids: [String],
                      tabIds: [Int],
                      intoGroupToken token: String,
                      atNormalTabsIdx normalTabsIdx: Int,
                      groupIndex: Int) -> Bool

    /// Inner table accepted or rejected a drag over this group. The
    /// controller maps this to `dropFeedbackTarget` container tinting.
    func tabGroupCell(_ cell: TabGroupCellView,
                      didUpdateDropTargetHighlight highlighted: Bool,
                      for group: WebContentGroupInfo)
}

/// Visual-only overlay; must not intercept mouse or drag hit-testing.
private final class TabGroupBorderOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

// MARK: - GroupTabsDiffableDataSource

/// Drag-source-aware subclass of `NSTableViewDiffableDataSource`. The
/// stock diffable data source conforms to `NSTableViewDataSource` but
/// has no opinion on drag sourcing — we override the three source
/// hooks and forward them to the host cell.
final class GroupTabsDiffableDataSource:
    NSTableViewDiffableDataSource<TabGroupCellView.Section, Int> {

    weak var dragSource: GroupTabsDragSource?

    // `@objc` is required for the AppKit drag/drop dispatcher to find
    // these optional `NSTableViewDataSource` hooks via the Objective-C
    // runtime. The Swift compiler does not auto-bridge dataSource
    // overrides on a generic `NSTableViewDiffableDataSource` subclass.
    // Explicit Objective-C selectors so AppKit's `respondsToSelector:`
    // probe always finds these hooks on a `NSTableViewDiffableDataSource`
    // subclass. Without the explicit selector form some Swift releases
    // mangle the selector for generic-base subclasses and the table
    // refuses to start a drag (no `pasteboardWriterForRow:` -> drag is
    // silently ignored).
    @objc(tableView:pasteboardWriterForRow:)
    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        return dragSource?.groupTabsPasteboardWriter(forRow: row)
    }

    @objc(tableView:draggingSession:willBeginAtPoint:forRowIndexes:)
    func tableView(_ tableView: NSTableView,
                   draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        dragSource?.groupTabsDraggingWillBegin(
            session: session, at: screenPoint, forRowIndexes: rowIndexes)
    }

    @objc(tableView:draggingSession:endedAtPoint:operation:)
    func tableView(_ tableView: NSTableView,
                   draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        dragSource?.groupTabsDraggingEnded(
            session: session, at: screenPoint, operation: operation)
    }

    @objc(tableView:validateDrop:proposedRow:proposedDropOperation:)
    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        return dragSource?.groupTabsValidateDrop(
            info, proposedRow: row, proposedDropOperation: dropOperation) ?? []
    }

    @objc(tableView:acceptDrop:row:dropOperation:)
    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        return dragSource?.groupTabsAcceptDrop(
            info, row: row, dropOperation: dropOperation) ?? false
    }
}

protocol GroupTabsDragSource: AnyObject {
    func groupTabsPasteboardWriter(forRow row: Int) -> NSPasteboardWriting?
    func groupTabsDraggingWillBegin(session: NSDraggingSession,
                                    at screenPoint: NSPoint,
                                    forRowIndexes rowIndexes: IndexSet)
    func groupTabsDraggingEnded(session: NSDraggingSession,
                                at screenPoint: NSPoint,
                                operation: NSDragOperation)
    func groupTabsValidateDrop(_ info: NSDraggingInfo,
                               proposedRow: Int,
                               proposedDropOperation: NSTableView.DropOperation) -> NSDragOperation
    func groupTabsAcceptDrop(_ info: NSDraggingInfo,
                             row: Int,
                             dropOperation: NSTableView.DropOperation) -> Bool
}

private protocol TabGroupHeaderHostingViewDelegate: AnyObject {
    func tabGroupHeaderHostingViewDidToggleCollapse(_ view: TabGroupHeaderHostingView)
    func tabGroupHeaderHostingViewDidRequestCloseGroup(_ view: TabGroupHeaderHostingView)
    func tabGroupHeaderHostingViewDidRequestOverview(_ view: TabGroupHeaderHostingView)
    func tabGroupHeaderHostingView(_ view: TabGroupHeaderHostingView,
                                   beginDraggingWith mouseDownEvent: NSEvent)
}

private final class TabGroupHeaderHostingView: NSHostingView<TabGroupHeaderView> {
    /// Slop matches `TabItemView` / `BookmarkItemView` so a click that
    /// drifts a couple of points doesn't get promoted to a drag.
    private static let dragThreshold: CGFloat = 5

    weak var dragDelegate: TabGroupHeaderHostingViewDelegate?

    private var pendingMouseDownEvent: NSEvent?
    private var pendingMouseDownPoint: NSPoint?
    private var pendingHitTarget: TabGroupHeaderHitTarget?
    private var manualDragInProgress = false

    override func mouseDown(with event: NSEvent) {
        pendingMouseDownEvent = event
        pendingMouseDownPoint = convert(event.locationInWindow, from: nil)
        pendingHitTarget = TabGroupHeaderHitTargetResolver.target(
            at: pendingMouseDownPoint ?? .zero,
            in: bounds
        )
        if pendingHitTarget == .closeGroup, rootView.viewModel.isHeaderHovered == false {
            pendingHitTarget = nil
        }
        manualDragInProgress = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !manualDragInProgress,
              pendingHitTarget == nil,
              let mouseDownEvent = pendingMouseDownEvent,
              let startPoint = pendingMouseDownPoint else {
            return
        }
        let currentPoint = convert(event.locationInWindow, from: nil)
        let dx = abs(currentPoint.x - startPoint.x)
        let dy = abs(currentPoint.y - startPoint.y)
        guard dx > Self.dragThreshold || dy > Self.dragThreshold else {
            return
        }
        manualDragInProgress = true
        dragDelegate?.tabGroupHeaderHostingView(
            self,
            beginDraggingWith: mouseDownEvent)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pendingMouseDownEvent = nil
            pendingMouseDownPoint = nil
            pendingHitTarget = nil
            manualDragInProgress = false
        }
        guard !manualDragInProgress else { return }

        // Close button uses standard cancel-on-drift semantics: fires
        // only when both mouseDown and mouseUp land inside the close
        // hit zone. A drift off the button cancels (no toggle either).
        if pendingHitTarget == .closeGroup {
            let upPoint = convert(event.locationInWindow, from: nil)
            let upTarget = TabGroupHeaderHitTargetResolver.target(at: upPoint, in: bounds)
            if upTarget == .closeGroup {
                dragDelegate?.tabGroupHeaderHostingViewDidRequestCloseGroup(self)
            }
            return
        }

        if pendingHitTarget == .toggleCollapse {
            let upPoint = convert(event.locationInWindow, from: nil)
            let upTarget = TabGroupHeaderHitTargetResolver.target(at: upPoint, in: bounds)
            if upTarget == .toggleCollapse {
                dragDelegate?.tabGroupHeaderHostingViewDidToggleCollapse(self)
            }
            return
        }

        let upPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(upPoint) else { return }

        // Cmd+click never opens the overview: a collapsed group expands,
        // an expanded group does nothing (in particular it must not clear
        // an active multi-selection).
        if event.modifierFlags.contains(.command) {
            if rootView.viewModel.isCollapsed {
                dragDelegate?.tabGroupHeaderHostingViewDidToggleCollapse(self)
            }
            return
        }

        dragDelegate?.tabGroupHeaderHostingViewDidRequestOverview(self)
    }
}

/// `NSTableCellView` host for a Chromium tab group: a SwiftUI header
/// strip on top + an embedded `GroupTabsTableView` rendering the
/// members. Replaces `TabGroupHeaderCellView`. The outer
/// `NSOutlineView` treats this row as a leaf with a dynamic height
/// (computed by `desiredHeight(for:browserState:)`).
final class TabGroupCellView: SidebarCellView {

    static let containerLeadingInset: CGFloat = WebContentConstant.edgesSpacing
    /// Container trailing is `0` so the rounded border aligns flush with
    /// the right edge of an ungrouped tab row.
    static let containerTrailingInset: CGFloat = WebContentConstant.edgesSpacing
    static let containerVerticalInset: CGFloat = 2
    static let headerHeight: CGFloat = 32
    /// Collapsed row height matches an ungrouped tab row (`36`). The
    /// container keeps its `containerVerticalInset` on both top and
    /// bottom across collapse states so the rounded card stays anchored
    /// at the same row-relative position during the collapse animation
    /// — the visible card height in collapsed state is therefore
    /// `collapsedRowHeight - 2 * containerVerticalInset` (32pt), exactly
    /// the header's natural height.
    static let collapsedRowHeight: CGFloat = 36
    /// Each member tab rendered by the inner table uses the same row
    /// height as an ungrouped tab in the outer outline.
    static let memberRowHeight: CGFloat = 36
    static let innerTableTopInset: CGFloat = 4
    static let innerTableBottomInset: CGFloat = 4
    static let innerTableLeadingInset: CGFloat = 0
    /// Inner tab card's own 8pt corner radius keeps it safely inside the
    /// container's 12pt corner curve, so the inner table can extend flush
    /// to the container's trailing edge — the inner card's right edge
    /// then aligns with both the group border line and an ungrouped tab
    /// card's right edge.
    static let innerTableTrailingInset: CGFloat = 4

    weak var groupCellDelegate: TabGroupCellViewDelegate?

    private(set) var token: String = ""

    private var containerView: NSView!
    private var containerBorderOverlayView: TabGroupBorderOverlayView!
    private var hostingView: TabGroupHeaderHostingView!
    private(set) var innerTable: GroupTabsTableView!
    private let viewModel = TabGroupHeaderViewModel()

    private var innerTableBottomConstraint: Constraint?
    private var innerTableCollapsedHeightConstraint: Constraint?

    private var dataSource: GroupTabsDiffableDataSource!
    private var tabsByGuid: [Int: Tab] = [:]
    private var currentMemberOrder: [Int] = []
    /// Non-pinned split pairs whose both panes are members of this group.
    /// Keyed by a negative integer derived from the two panes' guids so the
    /// row identifier stays stable across the pair's swap (the diff sees
    /// no change instead of remove+insert, which would flicker). Positive
    /// keys in `currentMemberOrder` map to `tabsByGuid` (regular tabs);
    /// negative keys map here (merged split rows).
    ///
    /// Holds `SplitPairSidebarItem` strongly so the inner-table cells'
    /// `weak item` ref stays valid for the lifetime of the pair in this
    /// group. Without this anchor the item would deallocate as soon as
    /// the data source's cell provider returned, and subsequent
    /// `Tab.$isActive` emissions would no-op in `SidebarSplitPairCellView.
    /// updateSelected` — leaving the merged cell's "selected" pill stuck
    /// on after the user switched away from one of the panes.
    private var splitPairsByKey: [Int: SplitPairSidebarItem] = [:]
    private var activeDragTabGuid: Int?

    private var isDropTargetHighlighted = false
    private var isHovered = false
    private var isOverviewSelected = false
    private var lastGroupColor: GroupColor = .grey
    private let hoverRegionView = SidebarTabHoverRegionView()

    private var collapseSubscription: AnyCancellable?
    private var colorSubscription: AnyCancellable?
    /// Re-runs `applyMembers` when this window's splits change so that a
    /// split formed/dissolved among already-adjacent group members shows
    /// up immediately (the outer `affectedGroupTokens` path only fires
    /// when the member [Int] sequence changes; a same-position split
    /// transition leaves the sequence unchanged).
    private var splitsSubscription: AnyCancellable?
    private weak var configuredGroup: WebContentGroupInfo?
    private weak var configuredBrowserState: BrowserState?
    private var isTemporarilyCollapsedForDrag = false

    enum Section: Hashable { case members }

    // MARK: - Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
        setupDataSource()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
        setupDataSource()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        viewModel.cancelSubscriptions()
        collapseSubscription?.cancel()
        collapseSubscription = nil
        colorSubscription?.cancel()
        colorSubscription = nil
        splitsSubscription?.cancel()
        splitsSubscription = nil
        tabsByGuid = [:]
        currentMemberOrder = []
        splitPairsByKey = [:]
        activeDragTabGuid = nil
        isDropTargetHighlighted = false
        isHovered = false
        isOverviewSelected = false
        viewModel.isHeaderHovered = false
        viewModel.isOverviewSelected = false
        isTemporarilyCollapsedForDrag = false
        configuredGroup = nil
        configuredBrowserState = nil

        var snap = NSDiffableDataSourceSnapshot<Section, Int>()
        snap.appendSections([.members])
        dataSource.apply(snap, animatingDifferences: false)
    }

    override func layout() {
        super.layout()
        if Self.isDebugVisualizeEnabled {
            logDebugFrames()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyHighlightVisuals()
    }

    // MARK: - Setup

    private func setupViews() {
        containerView = NSView()
        containerView.wantsLayer = true
        addSubview(containerView)
        containerView.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview().inset(Self.containerVerticalInset)
            make.leading.equalToSuperview().inset(Self.containerLeadingInset)
            make.trailing.equalToSuperview().inset(Self.containerTrailingInset)
        }

        hostingView = TabGroupHeaderHostingView(
            rootView: TabGroupHeaderView(viewModel: viewModel))
        hostingView.dragDelegate = self
        containerView.addSubview(hostingView)
        hostingView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(Self.headerHeight)
        }

        innerTable = GroupTabsTableView()
        innerTable.style = .plain
        innerTable.headerView = nil
        innerTable.gridStyleMask = []
        innerTable.backgroundColor = .clear
        innerTable.usesAutomaticRowHeights = false
        innerTable.rowHeight = Self.memberRowHeight
        innerTable.selectionHighlightStyle = .none
        innerTable.allowsEmptySelection = true
        innerTable.intercellSpacing = NSSize(width: 0, height: 0)
        // Naked `NSTableView` (not enclosed in `NSScrollView`) renders a
        // first-responder focus ring around the entire view by default;
        // hide it so the cell looks flush with the outer outline rows.
        innerTable.focusRingType = .none
        innerTable.phiTableDelegate = self
        innerTable.delegate = self
        innerTable.target = self
        innerTable.action = #selector(innerTableClicked(_:))
        // Same drag-source mask as the outer outline (`SidebarTabList
        // ViewController.viewDidLoad`) so cross-window drags work
        // identically to ungrouped tabs.
        innerTable.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        innerTable.setDraggingSourceOperationMask([.move, .copy], forLocal: false)
        innerTable.registerForDraggedTypes([
            .normalTab, .normalTabs, .pinnedTab, .phiBookmark, .bookmarks, .sourceWindowId
        ])

        // Cell width is controlled by `GroupTabsTableView.frameOfCell`,
        // not `column.width`, so the resizing mask here is irrelevant —
        // keep the AppKit default to avoid surprising any future code
        // that consults the column directly.
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("InnerGroupTab"))
        column.resizingMask = .autoresizingMask
        innerTable.addTableColumn(column)

        containerView.addSubview(innerTable)
        innerTable.snp.makeConstraints { make in
            make.top.equalTo(hostingView.snp.bottom).offset(Self.innerTableTopInset)
            make.leading.equalToSuperview().inset(Self.innerTableLeadingInset)
            make.trailing.equalToSuperview().inset(Self.innerTableTrailingInset)
            innerTableBottomConstraint = make.bottom.equalToSuperview()
                .inset(Self.innerTableBottomInset).constraint
            innerTableCollapsedHeightConstraint = make.height.equalTo(0).constraint
        }
        innerTableCollapsedHeightConstraint?.deactivate()

        containerBorderOverlayView = TabGroupBorderOverlayView()
        containerBorderOverlayView.wantsLayer = true
        containerBorderOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        containerBorderOverlayView.layer?.cornerRadius = 8
        containerBorderOverlayView.layer?.cornerCurve = .continuous
        containerBorderOverlayView.layer?.borderWidth = 1
        containerBorderOverlayView.layer?.borderColor = NSColor(resource: .commonBorder).cgColor
        // Suppress fade-in on hover/drop color flips while leaving
        // bounds/position animations alone — the height-change animation
        // driven by the outer outline view relies on those.
        containerBorderOverlayView.layer?.actions = [
            "borderColor": NSNull(),
            "borderWidth": NSNull(),
            "backgroundColor": NSNull(),
            "hidden": NSNull(),
        ]
        containerBorderOverlayView.isHidden = false
        containerView.addSubview(containerBorderOverlayView)
        containerBorderOverlayView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        applyHighlightVisuals()

        if Self.isDebugVisualizeEnabled {
            applyDebugTints()
        }

        hoverRegionView.onHoverChanged = { [weak self] isHovered in
            self?.setHovered(isHovered)
        }
        addSubview(hoverRegionView)
        hoverRegionView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private func setupDataSource() {
        dataSource = GroupTabsDiffableDataSource(
            tableView: innerTable
        ) { [weak self] tableView, _, _, key in
            guard let self else { return NSTableCellView() }
            // Merged-split row (negative key)
            if let pair = self.splitPairsByKey[key] {
                let identifier = NSUserInterfaceItemIdentifier("InnerGroupSplitPairCell")
                let cell: SidebarSplitPairCellView
                if let existing = tableView.makeView(
                    withIdentifier: identifier, owner: self) as? SidebarSplitPairCellView {
                    cell = existing
                } else {
                    cell = SidebarSplitPairCellView()
                    cell.identifier = identifier
                }
                cell.browserState = self.configuredBrowserState
                cell.owner = self.groupCellDelegate as? SidebarTabListItemOwner
                cell.configure(with: pair)
                return cell
            }
            guard let tab = self.tabsByGuid[key] else {
                return NSTableCellView()
            }
            let identifier = NSUserInterfaceItemIdentifier("InnerGroupTabCell")
            let cell: SidebarTabCellView
            if let existing = tableView.makeView(
                withIdentifier: identifier, owner: self) as? SidebarTabCellView {
                cell = existing
            } else {
                cell = SidebarTabCellView()
                cell.identifier = identifier
            }
            cell.delegate = self
            cell.configure(with: tab)
            cell.setActiveSuppressed(isOverviewSelected)
            return cell
        }
        dataSource.dragSource = self

        var snap = NSDiffableDataSourceSnapshot<Section, Int>()
        snap.appendSections([.members])
        dataSource.apply(snap, animatingDifferences: false)
    }

    // MARK: - Configuration

    override func configureAppearance() {
        guard let groupItem = item as? TabGroupSidebarItem,
              let state = MainBrowserWindowControllersManager.shared
                .controller(for: groupItem.windowId)?.browserState
        else { return }

        token = groupItem.group.token
        configuredGroup = groupItem.group
        configuredBrowserState = state
        isTemporarilyCollapsedForDrag = false
        viewModel.configure(with: groupItem.group, in: state)
        lastGroupColor = groupItem.group.color
        applyHighlightVisuals()

        let initialMembers = state.normalTabs.filter {
            $0.groupToken == groupItem.group.token
        }
        applyMembers(initialMembers, animated: false)

        applyEffectiveCollapseState()

        collapseSubscription?.cancel()
        let captureToken = groupItem.group.token
        collapseSubscription = groupItem.group.$isCollapsed
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.applyEffectiveCollapseState()
                self.groupCellDelegate?.tabGroupCellNeedsHeightUpdate(
                    self, for: captureToken, animated: true)
            }

        colorSubscription?.cancel()
        colorSubscription = groupItem.group.$color
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] color in
                guard let self, self.token == captureToken else { return }
                self.lastGroupColor = color
                self.applyHighlightVisuals()
            }

        splitsSubscription?.cancel()
        splitsSubscription = state.$splits
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self,
                      let groupItem = self.item as? TabGroupSidebarItem,
                      let state = self.configuredBrowserState else { return }
                let members = state.normalTabs.filter {
                    $0.groupToken == groupItem.group.token
                }
                self.applyMembers(members, animated: true)
            }
    }

    func setTemporarilyCollapsedForDrag(_ collapsed: Bool) {
        guard isTemporarilyCollapsedForDrag != collapsed else { return }
        isTemporarilyCollapsedForDrag = collapsed
        applyEffectiveCollapseState()
    }

    private var effectiveIsCollapsed: Bool {
        (configuredGroup?.isCollapsed ?? false) || isTemporarilyCollapsedForDrag
    }

    private func applyEffectiveCollapseState() {
        let collapsed = effectiveIsCollapsed
        innerTable.isHidden = collapsed
        updateLayoutForCollapseState(collapsed)
    }

    /// Container and header keep the same constraints across collapse
    /// states — the only thing that changes is the inner table's
    /// vertical extent: pinned to `container.bottom - innerTableBottomInset`
    /// when expanded, forced to `0` height when collapsed. Keeping the
    /// container's inset constant is what makes the rounded card's top
    /// and bottom edges stay anchored to the same row-relative positions
    /// during the collapse animation.
    private func updateLayoutForCollapseState(_ isCollapsed: Bool) {
        if isCollapsed {
            innerTableBottomConstraint?.deactivate()
            innerTableCollapsedHeightConstraint?.activate()
        } else {
            innerTableCollapsedHeightConstraint?.deactivate()
            innerTableBottomConstraint?.activate()
        }
        needsLayout = true
    }

    /// Apply a new member set, animating insertions/deletions/moves
    /// when `animated` is true. Always pushes a height update via the
    /// delegate so the outer outline can request a coordinated row
    /// resize.
    func applyMembers(_ newMembers: [Tab], animated: Bool) {
        tabsByGuid = Dictionary(
            uniqueKeysWithValues: newMembers.map { ($0.guid, $0) })
        // Detect non-pinned split pairs whose both panes live in this
        // group and are adjacent in the member order — render those as a
        // single merged row using a stable negative key derived from the
        // smaller guid (stable across pane swap).
        var pairs: [Int: SplitPairSidebarItem] = [:]
        var consumed = Set<Int>()
        var order: [Int] = []
        // Pair keys reused from the previous frame whose pane identity
        // changed (drag-to-replace swaps one pane's Tab while the key —
        // `-min(left, right)` — can survive when the kept pane has the
        // smaller guid). The diffable snapshot sees the same item id and
        // skips the cell provider, so the inner cell would stay bound to
        // the evicted tab; reloadItems below forces the re-bind.
        var changedPairKeys: [Int] = []
        for (idx, tab) in newMembers.enumerated() {
            if consumed.contains(tab.guid) { continue }
            if let state = configuredBrowserState,
               let group = state.splitGroup(forTabId: tab.guid),
               !group.isPinned,
               let partnerId = group.partnerTabId(of: tab.guid),
               let partnerIdx = newMembers.firstIndex(where: { $0.guid == partnerId }),
               abs(idx - partnerIdx) == 1 {
                let partner = newMembers[partnerIdx]
                let leftTab = idx < partnerIdx ? tab : partner
                let rightTab = idx < partnerIdx ? partner : tab
                let key = -min(leftTab.guid, rightTab.guid)
                // Reuse the existing `SplitPairSidebarItem` instance if the same
                // split is still here so the inner-table cell's `weak item` ref
                // doesn't dangle when `applyMembers` rebuilds. Pane swap is
                // surfaced via `SidebarSplitPairCellView.reresolvePairOrderIfNeeded`,
                // but we also mirror the latest left/right here so a freshly
                // configured cell sees the right order immediately.
                let item: SplitPairSidebarItem
                if let existing = splitPairsByKey[key], existing.groupId == group.id {
                    if existing.leftTab !== leftTab || existing.rightTab !== rightTab {
                        changedPairKeys.append(key)
                    }
                    if existing.leftTab !== leftTab { existing.leftTab = leftTab }
                    if existing.rightTab !== rightTab { existing.rightTab = rightTab }
                    item = existing
                } else {
                    item = SplitPairSidebarItem(
                        groupId: group.id,
                        leftTab: leftTab,
                        rightTab: rightTab,
                        browserState: state
                    )
                }
                pairs[key] = item
                order.append(key)
                consumed.insert(tab.guid)
                consumed.insert(partnerId)
                continue
            }
            order.append(tab.guid)
            consumed.insert(tab.guid)
        }
        splitPairsByKey = pairs
        currentMemberOrder = order

        var snap = NSDiffableDataSourceSnapshot<Section, Int>()
        snap.appendSections([.members])
        snap.appendItems(currentMemberOrder, toSection: .members)
        if !changedPairKeys.isEmpty {
            snap.reloadItems(changedPairKeys)
        }
        dataSource.apply(snap, animatingDifferences: animated)

        groupCellDelegate?.tabGroupCellNeedsHeightUpdate(
            self,
            for: token,
            animated: animated
        )
    }

    /// Cell-height formula. `BrowserState` is the live source of truth
    /// for member count, so this is computed each time the outline asks
    /// — the controller calls
    /// `outlineView.noteHeightOfRowsWithIndexesChanged` on relevant
    /// transitions to keep the displayed height in sync.
    static func desiredHeight(for groupItem: TabGroupSidebarItem,
                              browserState: BrowserState) -> CGFloat {
        if groupItem.group.isCollapsed {
            return collapsedRowHeight
        }
        let members = browserState.normalTabs.filter {
            $0.groupToken == groupItem.group.token
        }
        // Non-pinned split pairs collapse to a single row in the inner
        // table (mirrors `applyMembers`); the height must shrink with it
        // or we leave an empty slot below the merged row.
        let rowCount = effectiveRowCount(members: members, browserState: browserState)
        if rowCount == 0 {
            return collapsedRowHeight
        }
        return headerHeight
            + CGFloat(rowCount) * memberRowHeight
            + innerTableTopInset
            + innerTableBottomInset
            + containerVerticalInset * 2
    }

    /// Counts merged-cell rows the inner table will produce for `members`.
    /// Each non-pinned split pair whose two panes are adjacent counts once
    /// instead of twice. Stays in lockstep with `applyMembers`.
    private static func effectiveRowCount(members: [Tab],
                                          browserState: BrowserState) -> Int {
        var consumed = Set<Int>()
        var count = 0
        for (idx, tab) in members.enumerated() {
            if consumed.contains(tab.guid) { continue }
            if let group = browserState.splitGroup(forTabId: tab.guid),
               !group.isPinned,
               let partnerId = group.partnerTabId(of: tab.guid),
               let partnerIdx = members.firstIndex(where: { $0.guid == partnerId }),
               abs(idx - partnerIdx) == 1 {
                consumed.insert(tab.guid)
                consumed.insert(partnerId)
                count += 1
                continue
            }
            consumed.insert(tab.guid)
            count += 1
        }
        return count
    }

    // MARK: - Drop highlight

    func setDropTargetHighlighted(_ highlighted: Bool) {
        guard isDropTargetHighlighted != highlighted else { return }
        isDropTargetHighlighted = highlighted
        applyHighlightVisuals()
    }

    func setOverviewSelected(_ selected: Bool) {
        guard isOverviewSelected != selected else { return }
        isOverviewSelected = selected
        viewModel.isOverviewSelected = selected
        updateVisibleMemberActiveSuppression()
        applyHighlightVisuals()
    }

    private func updateVisibleMemberActiveSuppression() {
        for row in 0..<innerTable.numberOfRows {
            guard let cell = innerTable.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false
            ) as? SidebarTabCellView else {
                continue
            }
            cell.setActiveSuppressed(isOverviewSelected)
        }
    }

    private func applyHighlightVisuals() {
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 8
        containerView.layer?.cornerCurve = .continuous
        containerView.layer?.backgroundColor = NSColor.clear.cgColor

        containerBorderOverlayView.isHidden = false
        containerBorderOverlayView.layer?.backgroundColor =
            NSColor(resource: .sidebarTabHovered).cgColor
        containerBorderOverlayView.layer?.borderColor =
            NSColor(resource: .commonBorder).cgColor
    }

    /// Container border hover is driven by `hoverRegionView` (same
    /// transparent overlay pattern as `SidebarTabCellView`) so moves
    /// between the inner table and the SwiftUI header do not spuriously
    /// exit tracking. Header close-button visibility stays on
    /// `viewModel.isHeaderHovered` via SwiftUI `.onHover`.
    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        applyHighlightVisuals()
    }

    /// Resolves the context-menu owner for a right-click at `point` in
    /// this cell's coordinate space. Header hits use the group item;
    /// inner-table row hits use the member `Tab`.
    func contextMenuTarget(at pointInCell: NSPoint) -> ContextMenuRepresentable? {
        guard let groupItem = item as? TabGroupSidebarItem else {
            return nil
        }

        if effectiveIsCollapsed {
            return groupItem
        }

        let pointInContainer = containerView.convert(pointInCell, from: self)
        if hostingView.frame.contains(pointInContainer) {
            return groupItem
        }

        let pointInTable = innerTable.convert(pointInCell, from: self)
        let row = innerTable.row(at: pointInTable)
        if row >= 0,
           currentMemberOrder.indices.contains(row) {
            let key = currentMemberOrder[row]
            // Merged in-group split row: route through the left pane so
            // the user sees split-aware items (Pin Split, Remove from
            // Split, Add Split to Bookmark, …) instead of the group
            // menu that fires when the lookup falls through.
            if let pair = splitPairsByKey[key] {
                return pair.leftTab
            }
            if let tab = tabsByGuid[key] {
                return tab
            }
        }

        return groupItem
    }

    func draggingImageForMemberTabId(_ tabId: Int) -> NSImage? {
        guard let row = currentMemberOrder.firstIndex(where: { key in
            if let pair = splitPairsByKey[key] {
                return pair.leftTab.guid == tabId || pair.rightTab.guid == tabId
            }
            return key == tabId
        }) else {
            return nil
        }
        guard let cell = innerTable.view(
            atColumn: 0,
            row: row,
            makeIfNecessary: false
        ) as? SidebarCellView else {
            return nil
        }
        return cell.createDraggingImage()
    }
}

// MARK: - Click activation

extension TabGroupCellView {
    /// `NSTableView.action` target. Activates the clicked grouped tab
    /// the same way `outlineViewClicked` does for ungrouped rows —
    /// inner table's `selectionHighlightStyle = .none` skips the row
    /// highlight, and `Tab.performAction` simply swaps the active web
    /// content. Middle-click close and right-click menus are handled
    /// by `GroupTabsTableView` instead of this action hook.
    @objc fileprivate func innerTableClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0,
              currentMemberOrder.indices.contains(row)
        else { return }
        activateMemberRow(for: currentMemberOrder[row])
    }

    fileprivate func activateMemberRow(for key: Int) {
        if let pair = splitPairsByKey[key] {
            pair.performAction(with: nil)
            return
        }
        tabsByGuid[key]?.performAction(with: nil)
    }
}

// MARK: - Header drag

extension TabGroupCellView: TabGroupHeaderHostingViewDelegate {
    fileprivate func tabGroupHeaderHostingViewDidToggleCollapse(_ view: TabGroupHeaderHostingView) {
        guard let group = configuredGroup else { return }
        groupCellDelegate?.tabGroupCellDidToggleCollapse(self, group: group)
    }

    fileprivate func tabGroupHeaderHostingViewDidRequestCloseGroup(_ view: TabGroupHeaderHostingView) {
        guard let group = configuredGroup else { return }
        groupCellDelegate?.tabGroupCellDidRequestCloseGroup(self, group: group)
    }

    fileprivate func tabGroupHeaderHostingViewDidRequestOverview(_ view: TabGroupHeaderHostingView) {
        guard let group = configuredGroup else { return }
        // A plain click while multi-selecting exits the selection
        if let state = configuredBrowserState, state.multiSelection.isActive {
            state.clearMultiSelection()
        }
        groupCellDelegate?.tabGroupCellDidRequestOverview(self, group: group)
    }

    fileprivate func tabGroupHeaderHostingView(_ view: TabGroupHeaderHostingView,
                                               beginDraggingWith mouseDownEvent: NSEvent) {
        guard let group = configuredGroup else { return }
        AppLogDebug(
            "[TAB_GROUPS][GROUP_DRAG] cell.beginDraggingGroup token=\(group.token)"
        )
        groupCellDelegate?.tabGroupCell(
            self,
            beginDraggingGroup: group,
            from: containerView,
            mouseDownEvent: mouseDownEvent)
    }
}

// MARK: - NSTableViewDelegate

extension TabGroupCellView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // Defensive: even with `selectionHighlightStyle = .none` the
        // table still tracks selection internally. Returning `false`
        // keeps the inner selection set empty so SwiftUI's per-tab
        // `model.isActive` driver remains the sole active-state source.
        return false
    }
}

// MARK: - GroupTabsTableViewDelegate

extension TabGroupCellView: GroupTabsTableViewDelegate {
    func tableView(_ tableView: GroupTabsTableView,
                   beginDraggingRow row: Int,
                   with event: NSEvent) {
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] cell.beginDraggingRow row=\(row) " +
            "memberCount=\(currentMemberOrder.count)"
        )
        guard currentMemberOrder.indices.contains(row) else {
            AppLogDebug("[TAB_GROUPS][INNER_DRAG] cell.beginDraggingRow failed")
            return
        }
        let key = currentMemberOrder[row]
        let tab: Tab
        let rowView: SidebarCellView
        if let pair = splitPairsByKey[key] {
            // Merged in-group split row: drag carries the left pane's
            // guid; downstream drop handlers detect the tab is in a split
            // and reorder/pin/bookmark both panes as a unit.
            guard let cellView = tableView.view(
                atColumn: 0, row: row, makeIfNecessary: false) as? SidebarSplitPairCellView else {
                AppLogDebug("[TAB_GROUPS][INNER_DRAG] cell.beginDraggingRow failed (split cell missing)")
                return
            }
            tab = pair.leftTab
            rowView = cellView
        } else if let regularTab = tabsByGuid[key],
                  let cellView = tableView.view(
                    atColumn: 0, row: row, makeIfNecessary: false) as? SidebarTabCellView {
            tab = regularTab
            rowView = cellView
        } else {
            AppLogDebug("[TAB_GROUPS][INNER_DRAG] cell.beginDraggingRow failed (no view)")
            return
        }
        activeDragTabGuid = tab.guid
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] cell.beginDragging tab=\(tab.guid) token=\(token)"
        )
        groupCellDelegate?.tabGroupCell(self,
                                        beginDragging: tab,
                                        from: rowView,
                                        mouseDownEvent: event)
    }

    func tableView(_ tableView: GroupTabsTableView,
                   didClickRow row: Int) {
        guard currentMemberOrder.indices.contains(row) else {
            return
        }
        let key = currentMemberOrder[row]
        let modifierFlags = NSApp.currentEvent?.modifierFlags ?? []
        if let pair = splitPairsByKey[key],
           groupCellDelegate?.tabGroupCell(
               self,
               didRequestMultiSelectionFor: pair,
               modifierFlags: modifierFlags) == true {
            return
        }
        if let tab = tabsByGuid[key],
           groupCellDelegate?.tabGroupCell(
               self,
               didRequestMultiSelectionFor: tab,
               modifierFlags: modifierFlags) == true {
            return
        }
        if let state = configuredBrowserState {
            if state.multiSelection.isActive {
                state.clearMultiSelection()
            }
        }
        activateMemberRow(for: key)
    }

    func tableView(_ tableView: GroupTabsTableView,
                   didMiddleClickRow row: Int,
                   at location: NSPoint) {
        guard currentMemberOrder.indices.contains(row) else { return }
        let key = currentMemberOrder[row]
        if let pair = splitPairsByKey[key] {
            // Merged in-group split row renders both panes side-by-side —
            // route the close to the pane whose half the click landed in.
            // Use the cell frame so any leading inset doesn't pull midX
            // off the visible centerline between the two panes.
            let cellRect = tableView.frameOfCell(atColumn: 0, row: row)
            let target = location.x < cellRect.midX ? pair.leftTab : pair.rightTab
            groupCellDelegate?.tabGroupCell(self, tabDidRequestClose: target)
            return
        }
        guard let tab = tabsByGuid[key], !tab.isPinned else { return }
        groupCellDelegate?.tabGroupCell(self, tabDidRequestClose: tab)
    }

    func tableView(_ tableView: GroupTabsTableView,
                   didRequest target: GroupTabsTableInteractionTarget,
                   row: Int) {
        guard currentMemberOrder.indices.contains(row),
              let tab = tabsByGuid[currentMemberOrder[row]] else {
            return
        }

        switch target {
        case .close:
            groupCellDelegate?.tabGroupCell(self, tabDidRequestClose: tab)
        case .mute:
            tab.setAudioMuted(!tab.isAudioMuted)
        }
    }
}

// MARK: - GroupTabsDragSource

extension TabGroupCellView: GroupTabsDragSource {
    func groupTabsPasteboardWriter(forRow row: Int) -> NSPasteboardWriting? {
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] dataSource.pasteboardWriter row=\(row) " +
            "memberCount=\(currentMemberOrder.count)"
        )
        guard currentMemberOrder.indices.contains(row),
              let state = configuredBrowserState else {
            AppLogDebug("[TAB_GROUPS][INNER_DRAG] dataSource.pasteboardWriter nil")
            return nil
        }
        // Merged in-group split: write the left pane's guid so the
        // existing `.normalTab` drop handlers (reorder, pin, bookmark)
        // pick up the split-as-a-unit semantics automatically.
        let key = currentMemberOrder[row]
        let dragTab: Tab
        if let pair = splitPairsByKey[key] {
            dragTab = pair.leftTab
        } else if let tab = tabsByGuid[key] {
            dragTab = tab
        } else {
            return nil
        }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(String(dragTab.guid), forType: .normalTab)
        pasteboardItem.setString(String(state.windowId), forType: .sourceWindowId)
        let batchIds = state.multiSelectionDragTabIds(startingFrom: dragTab)
        if let ids = batchIds {
            pasteboardItem.setString(ids.map(String.init).joined(separator: ","),
                                     forType: .normalTabs)
        }
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] dataSource.pasteboardWriter guid=\(dragTab.guid) " +
            "windowId=\(state.windowId) batchIds=\(batchIds ?? [])"
        )
        return pasteboardItem
    }

    func groupTabsDraggingWillBegin(session: NSDraggingSession,
                                    at screenPoint: NSPoint,
                                    forRowIndexes rowIndexes: IndexSet) {
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] dataSource.willBegin rows=\(Array(rowIndexes)) " +
            "screen=\(screenPoint)"
        )
        guard let firstRow = rowIndexes.first,
              currentMemberOrder.indices.contains(firstRow) else {
            return
        }
        let key = currentMemberOrder[firstRow]
        let tab: Tab
        if let pair = splitPairsByKey[key] {
            tab = pair.leftTab
        } else if let regular = tabsByGuid[key] {
            tab = regular
        } else {
            return
        }
        activeDragTabGuid = tab.guid
        installDraggingImage(forRow: firstRow,
                             session: session,
                             screenPoint: screenPoint)
        groupCellDelegate?.tabGroupCell(self,
                                        draggingSessionWillBegin: session,
                                        at: screenPoint,
                                        for: tab)
    }

    func groupTabsDraggingEnded(session: NSDraggingSession,
                                at screenPoint: NSPoint,
                                operation: NSDragOperation) {
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] dataSource.ended screen=\(screenPoint) " +
            "operation=\(operation.rawValue)"
        )
        activeDragTabGuid = nil
        groupCellDelegate?.tabGroupCell(self,
                                        draggingSessionEnded: session,
                                        at: screenPoint,
                                        operation: operation)
    }

    private func installDraggingImage(forRow row: Int,
                                      session: NSDraggingSession,
                                      screenPoint: NSPoint) {
        guard let cell = innerTable.view(
            atColumn: 0,
            row: row,
            makeIfNecessary: false) as? SidebarTabCellView,
              let image = cell.createDraggingImage() else {
            AppLogDebug("[TAB_GROUPS][INNER_DRAG] cell.installDragImage failed row=\(row)")
            return
        }
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] cell.installDragImage row=\(row) " +
            "size=\(image.size)"
        )

        let frame = NSRect(
            x: screenPoint.x - image.size.width * 0.5,
            y: screenPoint.y - image.size.height * 0.5,
            width: image.size.width,
            height: image.size.height)
        session.enumerateDraggingItems(
            options: [],
            for: nil,
            classes: [NSPasteboardItem.self],
            searchOptions: [:]
        ) { draggingItem, _, _ in
            draggingItem.imageComponentsProvider = nil
            draggingItem.setDraggingFrame(frame, contents: image)
        }
    }

    func groupTabsValidateDrop(_ info: NSDraggingInfo,
                               proposedRow: Int,
                               proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let pasteboard = info.draggingPasteboard
        let insertionRow = resolvedInnerInsertionRow(
            proposedRow: proposedRow,
            dropOperation: dropOperation,
            draggingInfo: info)
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] inner.validateDrop row=\(proposedRow) " +
            "resolvedRow=\(insertionRow) op=\(dropOperation.rawValue) " +
            "types=\(pasteboard.types?.map(\.rawValue) ?? [])"
        )
        let result: NSDragOperation = {
            // Cross-window normal-tab joins are unsupported (mirrors the
            // outer resolver's `crossWindowGroupJoinUnsupported` reject).
            if let sourceIdString = pasteboard.string(forType: .sourceWindowId),
               let sourceId = Int(sourceIdString),
               let state = configuredBrowserState,
               sourceId != state.windowId {
                return []
            }
            if let pinnedGuid = pasteboard.string(forType: .pinnedTab) {
                guard !pinnedGuid.isEmpty,
                      groupCellDelegate?.tabGroupCell(
                        self,
                        canAcceptPinnedTabWithGuid: pinnedGuid) == true else {
                    return []
                }
                return .move
            }
            let bookmarkGuids = pasteboard.phiBookmarkGuids()
            if !bookmarkGuids.isEmpty {
                guard groupCellDelegate?.tabGroupCell(
                    self,
                    canAcceptBookmarksWithGuids: bookmarkGuids) == true else {
                    return []
                }
                return .move
            }
            if let bookmarkGuid = pasteboard.string(forType: .phiBookmark),
               !bookmarkGuid.isEmpty,
               groupCellDelegate?.tabGroupCell(self, canAcceptBookmarkWithGuid: bookmarkGuid) == true {
                return .move
            }
            return pasteboard.string(forType: .normalTab) != nil ? .move : []
        }()
        // Inner table accepts only between-row insertion. When AppKit reports
        // `.on`, choose the before/after insertion row from the cursor's
        // vertical half so dropping on a row's lower half can target the next
        // slot, including the position after the last visible member.
        if result == .move,
           (dropOperation == .on || insertionRow != proposedRow) {
            innerTable.setDropRow(insertionRow, dropOperation: .above)
        }
        if let group = configuredGroup {
            groupCellDelegate?.tabGroupCell(
                self,
                didUpdateDropTargetHighlight: result == .move,
                for: group)
        }
        AppLogDebug("[TAB_GROUPS][INNER_DRAG] inner.validateDrop -> \(result.rawValue)")
        return result
    }

    func groupTabsAcceptDrop(_ info: NSDraggingInfo,
                             row: Int,
                             dropOperation: NSTableView.DropOperation) -> Bool {
        let insertionRow = resolvedInnerInsertionRow(
            proposedRow: row,
            dropOperation: dropOperation,
            draggingInfo: info)
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] inner.acceptDrop row=\(row) " +
            "resolvedRow=\(insertionRow) op=\(dropOperation.rawValue)"
        )
        guard let state = configuredBrowserState,
              let group = configuredGroup
        else { return false }

        // `insertionRow` is in visible inner-table row space. Merged split
        // rows count once here but twice in `normalTabs`, so translate via
        // `currentMemberOrder` before calling the controller.
        let members = state.normalTabs.filter { $0.groupToken == group.token }
        let groupLowerBound: Int = {
            guard let firstMember = members.first,
                  let idx = state.normalTabs.firstIndex(of: firstMember)
            else { return state.normalTabs.count }
            return idx
        }()
        let normalTabsIdx = normalTabsInsertionIndex(
            forVisibleInsertionRow: insertionRow,
            members: members,
            groupLowerBound: groupLowerBound,
            state: state)
        let groupIndex = max(
            0,
            min(normalTabsIdx - groupLowerBound, members.count)
        )

        let pasteboard = info.draggingPasteboard
        let batchTabIds = pasteboard.phiNormalTabIds()
        let bookmarkGuids = pasteboard.phiBookmarkGuids()
        let accepted: Bool
        if let pinnedGuid = pasteboard.string(forType: .pinnedTab),
           !pinnedGuid.isEmpty {
            accepted = groupCellDelegate?.tabGroupCell(
                self,
                didAcceptPinnedTabWithGuid: pinnedGuid,
                intoGroupToken: group.token,
                atNormalTabsIdx: normalTabsIdx,
                groupIndex: groupIndex) ?? false
        } else if !bookmarkGuids.isEmpty {
            accepted = groupCellDelegate?.tabGroupCell(
                self,
                didAcceptBookmarksWithGuids: bookmarkGuids,
                tabIds: batchTabIds,
                intoGroupToken: group.token,
                atNormalTabsIdx: normalTabsIdx,
                groupIndex: groupIndex) ?? false
        } else if let bookmarkGuid = pasteboard.string(forType: .phiBookmark),
                  !bookmarkGuid.isEmpty {
            accepted = groupCellDelegate?.tabGroupCell(
                self,
                didAcceptBookmarkWithGuid: bookmarkGuid,
                intoGroupToken: group.token,
                atNormalTabsIdx: normalTabsIdx,
                groupIndex: groupIndex) ?? false
        } else if !batchTabIds.isEmpty {
            accepted = groupCellDelegate?.tabGroupCell(
                self,
                didAcceptTabsWithGuids: batchTabIds,
                intoGroupToken: group.token,
                atNormalTabsIdx: normalTabsIdx) ?? false
        } else if let guidString = pasteboard.string(forType: .normalTab),
                  let guid = Int(guidString),
                  let tab = state.tabs.first(where: { $0.guid == guid }) {
            accepted = groupCellDelegate?.tabGroupCell(
                self,
                didAcceptTab: tab,
                intoGroupToken: group.token,
                atNormalTabsIdx: normalTabsIdx) ?? false
        } else {
            accepted = false
        }
        AppLogDebug("[TAB_GROUPS][INNER_DRAG] inner.acceptDrop -> \(accepted)")
        return accepted
    }

    private func resolvedInnerInsertionRow(
        proposedRow: Int,
        dropOperation: NSTableView.DropOperation,
        draggingInfo: NSDraggingInfo
    ) -> Int {
        let rowCount = innerTable.numberOfRows
        let localPoint = innerTable.convert(draggingInfo.draggingLocation, from: nil)
        let rowFrame: CGRect? = {
            guard proposedRow >= 0, proposedRow < rowCount else { return nil }
            return innerTable.rect(ofRow: proposedRow)
        }()
        return Self.resolvedInnerInsertionRow(
            proposedRow: proposedRow,
            dropOperation: dropOperation,
            rowCount: rowCount,
            cursorY: localPoint.y,
            rowFrame: rowFrame,
            isFlipped: innerTable.isFlipped)
    }

    static func resolvedInnerInsertionRow(
        proposedRow: Int,
        dropOperation: NSTableView.DropOperation,
        rowCount: Int,
        cursorY: CGFloat,
        rowFrame: CGRect?,
        isFlipped: Bool
    ) -> Int {
        let clampedRow = min(max(0, proposedRow), rowCount)
        guard dropOperation == .on,
              proposedRow >= 0,
              proposedRow < rowCount,
              let rowFrame else {
            return clampedRow
        }

        let isLowerHalf = isFlipped
            ? cursorY >= rowFrame.midY
            : cursorY <= rowFrame.midY
        let insertionRow = isLowerHalf ? proposedRow + 1 : proposedRow
        return min(max(0, insertionRow), rowCount)
    }

    private func normalTabsInsertionIndex(
        forVisibleInsertionRow row: Int,
        members: [Tab],
        groupLowerBound: Int,
        state: BrowserState
    ) -> Int {
        let visibleRowCount = currentMemberOrder.count
        let clampedRow = min(max(0, row), visibleRowCount)
        guard clampedRow < visibleRowCount else {
            return groupLowerBound + members.count
        }

        let key = currentMemberOrder[clampedRow]
        if let pair = splitPairsByKey[key] {
            let leftIdx = state.normalTabs.firstIndex { $0.guid == pair.leftTab.guid }
            let rightIdx = state.normalTabs.firstIndex { $0.guid == pair.rightTab.guid }
            if let leftIdx, let rightIdx {
                return min(leftIdx, rightIdx)
            }
        }
        if let tab = tabsByGuid[key],
           let idx = state.normalTabs.firstIndex(where: { $0.guid == tab.guid }) {
            return idx
        }
        return groupLowerBound + min(clampedRow, members.count)
    }
}

// MARK: - TabCellDelegate

extension TabGroupCellView: TabCellDelegate {
    func tabCellDidRequestClose(_ tab: Tab) {
        groupCellDelegate?.tabGroupCell(self, tabDidRequestClose: tab)
    }
}

// MARK: - Runtime layout diagnostics

// Toggle at runtime:
//   defaults write <bundle-id> PhiTabGroupCellDebugVisualize -bool YES
// then relaunch. When the flag is off, this file is behaviorally identical
// to a build without the diagnostic. When on, every nested view gets a
// distinct 1pt tint border and per-frame values are logged after each
// `layout()` pass so we can visually correlate row / cell / container /
// header / innerTable / overlay frames against the missing bottom border.
extension TabGroupCellView {
    fileprivate static let debugVisualizeKey = "PhiTabGroupCellDebugVisualize"

    fileprivate static var isDebugVisualizeEnabled: Bool {
        UserDefaults.standard.bool(forKey: debugVisualizeKey)
    }

    fileprivate func applyDebugTints() {
        wantsLayer = true
        layer?.borderColor = NSColor.systemRed.cgColor
        layer?.borderWidth = 1

        containerView.wantsLayer = true
        containerView.layer?.borderColor = NSColor.systemGreen.cgColor
        containerView.layer?.borderWidth = 1

        hostingView.wantsLayer = true
        hostingView.layer?.borderColor = NSColor.systemOrange.cgColor
        hostingView.layer?.borderWidth = 1

        innerTable.wantsLayer = true
        innerTable.layer?.borderColor = NSColor.systemPurple.cgColor
        innerTable.layer?.borderWidth = 1

        containerBorderOverlayView.layer?.borderColor = NSColor.systemBlue.cgColor
        containerBorderOverlayView.layer?.borderWidth = 1
    }

    fileprivate func logDebugFrames() {
        let rowFrame = (superview as? NSTableRowView)?.frame ?? .zero
        let collapsed = configuredGroup?.isCollapsed ?? false
        let overlayLayerBounds = containerBorderOverlayView.layer?.bounds ?? .zero
        let overlayPresentationBounds = containerBorderOverlayView.layer?.presentation()?.bounds ?? .zero
        AppLogDebug(
            "[TAB_GROUPS][LAYOUT_DEBUG] token=\(token) collapsed=\(collapsed) " +
            "row=\(rowFrame) " +
            "cell.frame=\(frame) cell.bounds=\(bounds) cellFlipped=\(isFlipped) " +
            "container=\(containerView.frame) containerFlipped=\(containerView.isFlipped) " +
            "header=\(hostingView.frame) " +
            "innerTable=\(innerTable.frame) hidden=\(innerTable.isHidden) " +
            "overlay.frame=\(containerBorderOverlayView.frame) " +
            "overlay.layer.bounds=\(overlayLayerBounds) " +
            "overlay.layer.presentation.bounds=\(overlayPresentationBounds)"
        )
    }
}
