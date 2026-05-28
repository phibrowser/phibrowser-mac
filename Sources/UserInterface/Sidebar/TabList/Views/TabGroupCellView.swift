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
    /// `outlineView.noteHeightOfRowsWithIndexesChanged(_)`.
    func tabGroupCellNeedsHeightUpdate(_ cell: TabGroupCellView, for token: String)

    /// Inner table's chevron requested a collapse toggle. Controller
    /// dispatches to the bridge (mirrors the existing user-gesture
    /// path).
    func tabGroupCellDidToggleCollapse(_ cell: TabGroupCellView,
                                       group: WebContentGroupInfo)

    func tabGroupCellDidRequestCloseGroup(_ cell: TabGroupCellView,
                                          group: WebContentGroupInfo)

    func tabGroupCell(_ cell: TabGroupCellView,
                      beginDraggingGroup group: WebContentGroupInfo,
                      from headerView: NSView,
                      mouseDownEvent: NSEvent)

    /// Inner-table tab cell requested a close. Mirrors the route used
    /// by ungrouped tab cells via `TabCellDelegate`.
    func tabGroupCell(_ cell: TabGroupCellView,
                      tabDidRequestClose tab: Tab)

    /// Inner table detected a grouped-tab row drag. The controller owns
    /// the outer outline view, so it starts the AppKit drag session from
    /// that boundary while the cell supplies the row view snapshot.
    func tabGroupCell(_ cell: TabGroupCellView,
                      beginDragging tab: Tab,
                      from rowView: SidebarTabCellView,
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
    func tabGroupHeaderHostingView(_ view: TabGroupHeaderHostingView,
                                   beginDraggingWith mouseDownEvent: NSEvent)
}

private final class TabGroupHeaderHostingView: NSHostingView<TabGroupHeaderView> {
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
              let mouseDownEvent = pendingMouseDownEvent else {
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

        // Any other mouseUp on the header strip toggles collapse.
        dragDelegate?.tabGroupHeaderHostingViewDidToggleCollapse(self)
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
    private var containerBorderOverlayView: NSView!
    private var hostingView: TabGroupHeaderHostingView!
    private(set) var innerTable: GroupTabsTableView!
    private let viewModel = TabGroupHeaderViewModel()

    private var innerTableBottomConstraint: Constraint?
    private var innerTableCollapsedHeightConstraint: Constraint?

    private var dataSource: GroupTabsDiffableDataSource!
    private var tabsByGuid: [Int: Tab] = [:]
    private var currentMemberOrder: [Int] = []
    private var activeDragTabGuid: Int?

    private var isDropTargetHighlighted = false
    private var isHovered = false
    private var lastGroupColor: GroupColor = .grey
    private var hoverTrackingArea: NSTrackingArea?

    private var collapseSubscription: AnyCancellable?
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
        tabsByGuid = [:]
        currentMemberOrder = []
        activeDragTabGuid = nil
        isDropTargetHighlighted = false
        isHovered = false
        viewModel.isHeaderHovered = false
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(false)
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
            .normalTab, .pinnedTab, .phiBookmark, .sourceWindowId
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

        containerBorderOverlayView = NSView()
        containerBorderOverlayView.wantsLayer = true
        containerBorderOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        containerBorderOverlayView.layer?.cornerRadius = 8
        containerBorderOverlayView.layer?.cornerCurve = .continuous
        containerBorderOverlayView.layer?.borderWidth = 1
        containerBorderOverlayView.layer?.borderColor = NSColor.clear.cgColor
        // Suppress fade-in on hover/drop color flips while leaving
        // bounds/position animations alone — the height-change animation
        // driven by the outer outline view relies on those.
        containerBorderOverlayView.layer?.actions = [
            "borderColor": NSNull(),
            "borderWidth": NSNull(),
            "backgroundColor": NSNull(),
            "hidden": NSNull(),
        ]
        containerBorderOverlayView.isHidden = true
        containerView.addSubview(containerBorderOverlayView)
        containerBorderOverlayView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        applyHighlightVisuals()

        if Self.isDebugVisualizeEnabled {
            applyDebugTints()
        }
    }

    private func setupDataSource() {
        dataSource = GroupTabsDiffableDataSource(
            tableView: innerTable
        ) { [weak self] tableView, _, _, tabGuid in
            guard let self, let tab = self.tabsByGuid[tabGuid] else {
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
            // Bind to this group's owning window state BEFORE `configure(with:)`
            // so `updateSplitMembership` resolves splitPairPosition against it.
            // Without this, a split that joined the group renders as two
            // unmerged rows because `updateSplitMembership` falls into the
            // `browserState == nil` early-return branch.
            cell.browserState = self.configuredBrowserState
            cell.configure(with: tab)
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
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.applyEffectiveCollapseState()
                self.groupCellDelegate?.tabGroupCellNeedsHeightUpdate(
                    self, for: captureToken)
            }
    }

    /// Result of compositing a split-pair drag image for an inner-row drag.
    /// `image` is the stacked snapshot, `upperHeight` is the height of the
    /// upper pane snapshot (used to anchor the dragging frame when the
    /// dragged pane is the lower one), and `isDraggedUpper` says whether
    /// the originally-dragged row is the upper one in the composite.
    struct SplitPairCompositeImage {
        let image: NSImage
        let upperHeight: CGFloat
        let isDraggedUpper: Bool
    }

    /// If `tab` is one pane of a split whose other pane is also a member
    /// of this group, stack both panes' inner-table cell snapshots into
    /// one composite drag image so the drag lifts the pair as a unit.
    /// Returns nil when the tab isn't in a split, the partner isn't a
    /// visible member of this group's inner table, or the snapshots
    /// can't be produced.
    func splitPairCompositeForInnerRow(
        tab: Tab,
        draggedRowView: SidebarTabCellView,
        draggedImage: NSImage,
        stack: (NSImage, NSImage) -> NSImage?
    ) -> SplitPairCompositeImage? {
        guard let state = configuredBrowserState,
              let group = state.splitGroup(forTabId: tab.guid),
              let partnerId = group.partnerTabId(of: tab.guid),
              let draggedRow = currentMemberOrder.firstIndex(of: tab.guid),
              let partnerRow = currentMemberOrder.firstIndex(of: partnerId),
              let partnerCell = innerTable.view(
                atColumn: 0, row: partnerRow, makeIfNecessary: false)
                as? SidebarTabCellView,
              let partnerSnapshot = partnerCell.createDraggingImage() else {
            return nil
        }
        let isDraggedUpper = draggedRow < partnerRow
        let upperSnapshot = isDraggedUpper ? draggedImage : partnerSnapshot
        let lowerSnapshot = isDraggedUpper ? partnerSnapshot : draggedImage
        guard let composite = stack(upperSnapshot, lowerSnapshot) else {
            return nil
        }
        return SplitPairCompositeImage(
            image: composite,
            upperHeight: upperSnapshot.size.height,
            isDraggedUpper: isDraggedUpper
        )
    }

    /// Re-run `updateSplitMembership` on every visible member cell.
    /// Called from the controller's `$splits` / `$focusingTab`
    /// subscription so a split that joined this group (or whose pair
    /// flipped state) re-renders with the merged-bar appearance
    /// immediately, without waiting for the cell to be reconfigured.
    func refreshMemberSplitMembership() {
        for row in 0..<innerTable.numberOfRows {
            guard let cell = innerTable.view(
                atColumn: 0, row: row, makeIfNecessary: false)
                as? SidebarTabCellView else { continue }
            cell.updateSplitMembership()
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
        currentMemberOrder = newMembers.map(\.guid)

        var snap = NSDiffableDataSourceSnapshot<Section, Int>()
        snap.appendSections([.members])
        snap.appendItems(currentMemberOrder, toSection: .members)
        dataSource.apply(snap, animatingDifferences: animated)

        groupCellDelegate?.tabGroupCellNeedsHeightUpdate(self, for: token)
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
        let memberCount = browserState.normalTabs.lazy
            .filter { $0.groupToken == groupItem.group.token }.count
        if memberCount == 0 {
            return collapsedRowHeight
        }
        return headerHeight
            + CGFloat(memberCount) * memberRowHeight
            + innerTableTopInset
            + innerTableBottomInset
            + containerVerticalInset * 2
    }

    // MARK: - Drop highlight

    func setDropTargetHighlighted(_ highlighted: Bool) {
        guard isDropTargetHighlighted != highlighted else { return }
        isDropTargetHighlighted = highlighted
        applyHighlightVisuals()
    }

    private func applyHighlightVisuals() {
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 8
        containerView.layer?.cornerCurve = .continuous
        containerView.layer?.backgroundColor = NSColor.clear.cgColor

        if isDropTargetHighlighted {
            let groupColor = configuredGroup?.color ?? lastGroupColor
            let tint = groupColor.nsColor
            // Tint lives on the overlay (topmost subview). The header
            // hosting view and inner table sit above `containerView.layer`,
            // so a background on the container itself is never visible.
            containerBorderOverlayView.isHidden = false
            containerBorderOverlayView.layer?.backgroundColor =
                groupColor.chipTintColor.cgColor
            containerBorderOverlayView.layer?.borderColor =
                tint.withAlphaComponent(0.36).cgColor
        } else if isHovered {
            containerBorderOverlayView.isHidden = false
            containerBorderOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
            containerBorderOverlayView.layer?.borderColor =
                ThemedColor.border.resolve(in: containerView).cgColor
        } else {
            containerBorderOverlayView.isHidden = true
            containerBorderOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
            containerBorderOverlayView.layer?.borderColor = NSColor.clear.cgColor
        }
    }

    /// Cell-level hover tracked by an AppKit tracking area on the full
    /// cell bounds — only drives the rounded border highlight. The
    /// header-specific hover (which controls the close button's
    /// visibility) lives on `viewModel.isHeaderHovered` and is written
    /// from SwiftUI's `.onHover` inside `TabGroupHeaderView`, so the
    /// two states stay scoped to their respective hit regions.
    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        applyHighlightVisuals()
    }
}

// MARK: - Click activation

extension TabGroupCellView {
    /// `NSTableView.action` target. Activates the clicked grouped tab
    /// the same way `outlineViewClicked` does for ungrouped rows —
    /// inner table's `selectionHighlightStyle = .none` skips the row
    /// highlight, and `Tab.performAction` simply swaps the active web
    /// content. Middle/right clicks do not flow through this hook;
    /// they're handled by the inner table's default behavior.
    @objc fileprivate func innerTableClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0,
              currentMemberOrder.indices.contains(row),
              let tab = tabsByGuid[currentMemberOrder[row]]
        else { return }
        tab.performAction(with: nil)
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
        guard currentMemberOrder.indices.contains(row),
              let tab = tabsByGuid[currentMemberOrder[row]],
              let rowView = tableView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false) as? SidebarTabCellView else {
            AppLogDebug("[TAB_GROUPS][INNER_DRAG] cell.beginDraggingRow failed")
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
        guard currentMemberOrder.indices.contains(row),
              let tab = tabsByGuid[currentMemberOrder[row]] else {
            return
        }
        tab.performAction(with: nil)
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
        let guid = currentMemberOrder[row]
        guard tabsByGuid[guid] != nil else { return nil }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(String(guid), forType: .normalTab)
        pasteboardItem.setString(String(state.windowId), forType: .sourceWindowId)
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] dataSource.pasteboardWriter guid=\(guid) " +
            "windowId=\(state.windowId)"
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
              currentMemberOrder.indices.contains(firstRow),
              let tab = tabsByGuid[currentMemberOrder[firstRow]] else {
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
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] inner.validateDrop row=\(proposedRow) " +
            "op=\(dropOperation.rawValue) types=\(pasteboard.types?.map(\.rawValue) ?? [])"
        )
        // Inner table only accepts drops *between* rows, not "on" them.
        // Promote `.on` to `.above` so AppKit shows the insertion line
        // instead of the row-highlight feedback.
        if dropOperation == .on {
            innerTable.setDropRow(proposedRow, dropOperation: .above)
        }
        // A split that joined this group must render and behave as a
        // single unit. If the proposed drop falls strictly between the
        // two panes (i.e., `proposedRow` is the second pane's row index
        // with `.above`), snap to whichever side of the pair the cursor
        // is closer to — matching the outer outline's
        // `snapDropChildIndexOutsideSplitPair` behavior.
        let snappedRow = snapDropRowOutsideInnerSplitPair(
            proposedRow: proposedRow,
            dropOperation: dropOperation,
            draggingLocation: info.draggingLocation,
            draggedGuid: pasteboard.string(forType: .normalTab).flatMap { Int($0) })
        if snappedRow != proposedRow {
            innerTable.setDropRow(snappedRow, dropOperation: .above)
        }
        // Pinned and bookmark drops never join a group.
        if pasteboard.string(forType: .pinnedTab) != nil { return [] }
        if pasteboard.string(forType: .phiBookmark) != nil { return [] }
        // Cross-window normal-tab joins are unsupported (mirrors the
        // outer resolver's `crossWindowGroupJoinUnsupported` reject).
        if let sourceIdString = pasteboard.string(forType: .sourceWindowId),
           let sourceId = Int(sourceIdString),
           let state = configuredBrowserState,
           sourceId != state.windowId {
            return []
        }
        let result: NSDragOperation = pasteboard.string(forType: .normalTab) != nil ? .move : []
        AppLogDebug("[TAB_GROUPS][INNER_DRAG] inner.validateDrop -> \(result.rawValue) snappedRow=\(snappedRow)")
        return result
    }

    /// If `proposedRow` would drop a tab strictly between the two panes
    /// of a split that lives inside this group, return the closest legal
    /// row on whichever side the cursor's y-coordinate indicates.
    /// Otherwise return `proposedRow` unchanged. The dragged tab itself
    /// is allowed to land between its own split's panes (no-op for
    /// in-pair moves — those go through `moveSplit` / `reverseTabs`).
    private func snapDropRowOutsideInnerSplitPair(
        proposedRow: Int,
        dropOperation: NSTableView.DropOperation,
        draggingLocation: NSPoint,
        draggedGuid: Int?) -> Int {
        // `dropOperation` is checked by callers; we only need to snap
        // based on the row regardless of the incoming op. The validate
        // path promotes `.on` to `.above` *before* calling this, then
        // calls `setDropRow(snapped, .above)` — but if we early-returned
        // on a non-`.above` op the visual indicator would stay parked on
        // the seam even after the accept-side already moved off it.
        guard let state = configuredBrowserState else {
            return proposedRow
        }
        for split in state.splits {
            guard let primaryRow = currentMemberOrder.firstIndex(of: split.primaryTabId),
                  let secondaryRow = currentMemberOrder.firstIndex(of: split.secondaryTabId) else {
                continue
            }
            let lo = min(primaryRow, secondaryRow)
            let hi = max(primaryRow, secondaryRow)
            guard hi == lo + 1, proposedRow == hi else { continue }
            // The moving tab IS one of the split's panes — let the inner
            // table handle it the same way as any tab move; the `moveTab
            // intoGroup` flow keeps the split intact via
            // `enforceSplitAdjacency`.
            if let draggedGuid,
               draggedGuid == split.primaryTabId || draggedGuid == split.secondaryTabId {
                continue
            }
            let loRect = innerTable.rect(ofRow: lo)
            let hiRect = innerTable.rect(ofRow: hi)
            let boundaryY = (loRect.midY + hiRect.midY) / 2
            let pointInTable = innerTable.convert(draggingLocation, from: nil)
            let pointerOnUpperHalf = innerTable.isFlipped
                ? pointInTable.y < boundaryY
                : pointInTable.y > boundaryY
            return pointerOnUpperHalf ? lo : hi + 1
        }
        return proposedRow
    }

    func groupTabsAcceptDrop(_ info: NSDraggingInfo,
                             row: Int,
                             dropOperation: NSTableView.DropOperation) -> Bool {
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] inner.acceptDrop row=\(row) " +
            "op=\(dropOperation.rawValue)"
        )
        guard let state = configuredBrowserState,
              let group = configuredGroup,
              let guidString = info.draggingPasteboard.string(forType: .normalTab),
              let guid = Int(guidString),
              let tab = state.tabs.first(where: { $0.guid == guid })
        else { return false }

        // Apply the same split-pair snap as validateDrop so the actual
        // insertion index stays out of the gap between the two panes
        // even when AppKit passes the original proposedRow through
        // unchanged on .acceptDrop.
        let snappedRow = snapDropRowOutsideInnerSplitPair(
            proposedRow: row,
            dropOperation: dropOperation,
            draggingLocation: info.draggingLocation,
            draggedGuid: guid)

        // `proposedRow` is in inner-table indices (0..<memberCount).
        // The outer normal-tabs index = group's lower bound + row.
        let members = state.normalTabs.filter { $0.groupToken == group.token }
        let groupLowerBound: Int = {
            guard let firstMember = members.first,
                  let idx = state.normalTabs.firstIndex(of: firstMember)
            else { return state.normalTabs.count }
            return idx
        }()
        let clampedRow = min(max(0, snappedRow), members.count)
        let normalTabsIdx = groupLowerBound + clampedRow

        let accepted = groupCellDelegate?.tabGroupCell(
            self,
            didAcceptTab: tab,
            intoGroupToken: group.token,
            atNormalTabsIdx: normalTabsIdx) ?? false
        AppLogDebug("[TAB_GROUPS][INNER_DRAG] inner.acceptDrop -> \(accepted) snappedRow=\(snappedRow)")
        return accepted
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
