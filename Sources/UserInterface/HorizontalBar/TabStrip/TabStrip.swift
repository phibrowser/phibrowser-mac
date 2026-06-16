// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit

private final class DragOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let drag overlay events pass through to the real tab views.
        return nil
    }
}

final class TabStrip: NSView, TitlebarAwareHitTestable {
    func shouldConsumeHitTest(at point: NSPoint) -> Bool {
        if let event = NSApp.currentEvent, event.type == .rightMouseDown {
            return true
        }
        return false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // When the hit lands on empty container space (no tab item or button),
        // return self so TitlebarTransparentView recognises TitlebarAwareHitTestable
        // and passes the event to the system for window operations (double-click zoom, drag, etc.).
        if hit === normalContainer || hit === pinnedContainer {
            return self
        }
        return hit
    }

    private struct ExternalDropTarget {
        let windowController: MainBrowserWindowController
        let zone: TabContainerType
        let index: Int
        /// Non-nil when the resolved intent is JOIN. Identifies the
        /// target group. Nil = OUTSIDE (no auto-join on commit).
        let targetGroupToken: String?
        /// Which side of the anchor tab to insert on (selects the
        /// before-vs-after Chromium bridge). Meaningless when
        /// `targetGroupToken` is nil.
        let joinAnchorIsBefore: Bool
    }

    /// Resolved cross-window single-tab drop intent. Produced by
    /// `resolveSingleTabDropIntent(forScreenPoint:)` and consumed by
    /// BOTH the preview path (`updateExternalDragPreview`) and the
    /// commit path (`resolveExternalDropTarget`). Both call sites
    /// route through the same resolver — that's how visual/commit
    /// agreement is guaranteed.
    private struct SingleTabDropIntent {
        /// Resolved zone (pinned vs normal). JOIN only fires in
        /// normal; pinned passes through with `joinGroupToken == nil`.
        let zone: TabContainerType
        /// Final commit index. For JOIN this lives inside the target
        /// run; for OUTSIDE this is a run boundary or unconstrained
        /// raw index.
        let index: Int
        /// Non-nil = JOIN target group token. Nil = OUTSIDE.
        let joinGroupToken: String?
        /// true = before-tab bridge; false = after-tab. Meaningless
        /// when `joinGroupToken` is nil.
        let joinAnchorIsBefore: Bool
    }

    private enum PendingDropAction {
        case local
        case external(ExternalDropTarget)
        case tearOff
        /// Drop landed on the same window's WebContent area in a side zone:
        /// pair the dragged tab with the focused tab into a new vertical split.
        case splitWithFocused(SplitTabDropContainer.DropZone)
    }

    // MARK: - Dependencies
    private let browserState: BrowserState
    private var cancellables = Set<AnyCancellable>()
    /// Per-group `objectWillChange` subscriptions. `WebContentGroupInfo`
    /// is a class — its title / color / collapsed mutations don't
    /// republish `BrowserState.$groups`, and tab → group membership
    /// flips don't republish `$normalTabs` either. Both nudge
    /// `info.objectWillChange.send()`, so we mirror the sidebar's
    /// approach and re-subscribe whenever the dictionary changes.
    private var groupChangeCancellables: [String: AnyCancellable] = [:]

    /// Combine subscriptions for collapsed-group member favicons.
    /// Keyed by group token; each value's `Set<AnyCancellable>`
    /// holds one subscription per observed member (≤4 per group).
    /// Reconciled by `rebuildCollapsedGroupFaviconSubscriptions()`
    /// whenever groups or tab membership change.
    private var collapsedGroupFaviconCancellables: [String: Set<AnyCancellable>] = [:]
    private let dragController = TabStripDragController()
    private let groupDragController = TabGroupDragController()
    private var isActive = false

    /// Local NSEvent monitor installed for the lifetime of a group
    /// drag — listens for the Esc key (keyCode 53) and cancels the
    /// drag. Local-only so it doesn't leak past this app's events.
    private var groupDragEscMonitor: Any?

    /// UI-only overlay for whole-group drag: while non-nil, the group
    /// identified by this token is rendered as collapsed (mosaic chip,
    /// zero-width members) regardless of its persisted
    /// `BrowserState.groups[token].isCollapsed`. Set at drag start when
    /// the dragged group is expanded so the proxy + let-way calc use
    /// chipW instead of chipW + members; cleared at drop / cancel.
    /// Never written to Chromium.
    private var temporarilyCollapsedGroupTokenForDrag: String?

    /// True while `animateGroupDragSettle`'s NSAnimationContext is in
    /// flight (the post-drop / post-cancel reflow). Layout passes that
    /// land during this window must NOT reassign frames or transforms
    /// instantly — that would cancel the in-flight CA animation and
    /// snap the chip to its destination. See `layout()` for the gate.
    private var groupDragSettling: Bool = false

    /// Monotonic counter bumped at the start of every
    /// `animateGroupDragSettle` call. The completion handler only
    /// clears `groupDragSettling` when its captured generation still
    /// matches the current one — protects against a stale completion
    /// (from settle N) firing during settle N+1's animation window
    /// and prematurely re-enabling layout()'s else branch, which
    /// would snap settle N+1 to its end state. Triggered when the
    /// user drops two whole-group drags within ~180ms.
    private var groupDragSettleGeneration: Int = 0

    /// Chip's `metricsSpace.minX` captured in `chip.onDragStart` BEFORE
    /// the temp-collapse relayout. Consumed once by
    /// `groupDragControllerSnapshot` to compute `chipPositionShift` and
    /// override the snapshot's `chipFrame` with the pre-relayout
    /// position. Cleared after the snapshot is built (or after
    /// `startDragging` returns) so it doesn't leak into a later drag.
    private var chipPreCollapseMetricsMinXForDrag: CGFloat?

    // MARK: - Scroll
    private var currentScrollOffset: CGFloat = 0.0
    private var lastContentWidth: CGFloat = 0.0

    private let containerMaskLayer = CAShapeLayer()

    /// Notifies the parent (TabStripBarController) whenever the strip relayouts
    /// so the content border outline can recompute its active-tab gap.
    var onLayoutChanged: (() -> Void)?

    // MARK: - View Pools
    private var pinnedTabViews: [String: TabItemView] = [:]
    private var normalTabViews: [String: TabItemView] = [:]
    /// Reusable separator views.
    private var separatorViews: [NSView] = []

    // MARK: - Group view pools
    private var chipViews: [String: TabGroupChipView] = [:]
    /// Right-side separator view per chip, keyed by group token.
    /// Sits between chip and its right neighbor in flow; same visual
    /// metrics as the tab↔tab separators in `separatorViews`.
    private var chipRightSeparatorViews: [String: NSView] = [:]
    // Note: per-group underlines are no longer drawn here. They live
    // alongside the active-tab outline in `WebContentContainerViewController`,
    // tracing one unified path per group, so the chip/underline/active
    // outline have no perpendicular seams between them. The chips
    // themselves remain in the strip's normalContainer.

    /// Pre-measured chip widths in `.full` mode, keyed by token. Refreshed
    /// when title / color / member count changes; passed to the layout
    /// engine via `TabStripLayoutInput.chipFullWidths`.
    private var chipFullWidths: [String: CGFloat] = [:]

    /// Hovered normal-tab index.
    private var hoveredTabIndex: Int?
    /// Token of the currently-hovered group chip, if any. Used by
    /// `updateSeparators` / `updateChipRightSeparators` to hide the
    /// separators on both sides of the chip while hovered (mirrors the
    /// tab hover rule).
    private var hoveredChipToken: String?
    private var selectedGroupTokenForOverviewPlaceholder: String?

    // MARK: - Layout Lock
    /// Whether layout is temporarily locked after a tab closes.
    private var isLayoutLocked = false
    /// Cached inactive-tab width while layout is locked.
    private var lockedTabWidth: CGFloat?
    /// Previous normal-tab count, used to detect tab closes.
    private var previousNormalTabCount: Int = 0
    /// Trailing normal-tab id from the previous tick. The close sink only
    /// sees the post-close list, so a trailing close is detected by this
    /// id having vanished from it.
    private var previousTrailingNormalTabId: Int?

    private struct ExternalDragPreview {
        let zone: TabContainerType
        let index: Int
        let gapWidth: CGFloat?
        /// Non-nil means "JOIN this specific run". Nil means OUTSIDE.
        /// Drives the gap-side gating (Task B7) and the underline
        /// rightX extension for trailingJoin (Task B8).
        let joinRunToken: String?
    }

    // Overlay used to display the dragged tab outside container clipping.
    private lazy var dragOverlay: DragOverlayView = {
        let view = DragOverlayView()
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        view.isHidden = true
        return view
    }()

    // Proxy tab view shown during drag without binding to the data source.
    private var draggingProxyView: TabItemView?
    // Companion proxy for the dragged tab's split partner so the pair lifts
    // and travels together. nil for non-split drags.
    private var draggingSiblingProxyView: TabItemView?
    // Real source view that still owns mouse events during the drag.
    private weak var draggingSourceView: TabItemView?
    // Source view of the split partner, hidden during the drag and revealed
    // when the drag ends. nil for non-split drags.
    private weak var draggingSiblingSourceView: TabItemView?
    // Resolved layout for the sibling proxy: its index in the source zone and
    // pixel offset from the primary proxy at drag start (positive when the
    // partner is to the right). nil for non-split drags.
    private var draggingSiblingPlacement: (index: Int, offsetX: CGFloat)?
    // Container zone currently used for drag presentation styling.
    private var draggingPresentationZone: TabContainerType?
    // When the dragged source is the first pane of a merged split cell
    // (normal or pinned), holds the partner pane so the proxy keeps the
    // two-favicon merged-cell rendering after a cross-zone restyle.
    private weak var draggingMergedPartner: Tab?
    private var dragImageWindow: NSPanel?
    private var dragImageView: NSImageView?
    private var cachedTabDragImage: NSImage?
    private var cachedPageDragImage: NSImage?
    private var externalDragPreview: ExternalDragPreview?
    private weak var externalPreviewTargetStrip: TabStrip?
    /// Per-chip "was gap-before-chip" hysteresis flag for the cross-window
    /// resolver. Stores the token of the chip currently in
    /// "gap-before-chip" state on THIS strip; nil = no chip currently in
    /// that state. Same-window keeps the analog (`gapBeforeRunStartChipToken`)
    /// on `TabDragContext`; cross-window has no such context on the target
    /// strip, so the state lives here. Reset by the resolver itself when
    /// the cursor no longer hits any chip, and defensively by
    /// `clearExternalDragPreview`.
    private var externalHoverGapBeforeChipToken: String?
    /// 300ms hover-to-expand timer for a collapsed target chip during
    /// external single-tab drag. See spec §6 (Edge cases — collapsed
    /// chip). Token of the chip the timer is currently armed for;
    /// nil = no timer running.
    private var collapsedChipExpandTimer: Timer?
    private var collapsedChipExpandToken: String?
    private var lastDragScreenPoint: CGPoint?
    private var pendingDropAction: PendingDropAction?
    /// Drop container we last asked to show a split hint. Held so we can clear
    /// the hint when the cursor leaves the zone (or the drag ends).
    private weak var splitHintTargetContainer: SplitTabDropContainer?

    // Offset = inverseCornerRadius - gapBetweenPinnedAndNormal
    private let normalTabContainerOffset = max(0, TabStripMetrics.Tab.inverseCornerRadius - TabStripMetrics.Strip.gapBetweenPinnedAndNormal)

    // MARK: - Subviews
    private lazy var newTabButton: NewTabButton = {
        let btn = NewTabButton()
        btn.onTap = { [weak self] in
            self?.handleNewTabButtonClick()
        }
        return btn
    }()

    // MARK: - Containers

    // Pinned-tab container.
    private lazy var pinnedContainer: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(resource: .sidebarTabHovered).cgColor
        view.layer?.cornerRadius = TabStripMetrics.Strip.pinnedContainerCornerRadius
        return view
    }()

    // Normal-tab container.
    private lazy var normalContainer: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        return view
    }()

    // MARK: - Initialization
    init(browserState: BrowserState) {
        self.browserState = browserState
        super.init(frame: .zero)
        dragController.delegate = self
        groupDragController.delegate = self
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup UI
    private func setupUI() {
        wantsLayer = true

        addSubview(pinnedContainer)
        addSubview(normalContainer)
        addSubview(newTabButton)
        addSubview(dragOverlay)

        newTabButton.snp.makeConstraints { make in
            make.size.equalTo(TabStripMetrics.NewTabButton.size)
        }

        let tabHeight = TabStripMetrics.Strip.tabHeight
        let bottomSpacing = TabStripMetrics.Strip.bottomSpacing

        pinnedContainer.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.width.equalTo(0)
            make.height.equalTo(tabHeight)
            make.bottom.equalToSuperview().offset(-bottomSpacing)
        }

        normalContainer.snp.makeConstraints { make in
            make.leading.equalTo(pinnedContainer.snp.trailing).offset(-1 * normalTabContainerOffset)
            make.height.equalTo(tabHeight + bottomSpacing)
            make.trailing.equalToSuperview()
        }

        dragOverlay.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    override func layout() {
        super.layout()
        updateNormalContainerMask()

        let pinnedTabs = browserState.pinnedTabs
        let normalTabs = browserState.normalTabs
        let activeTab = visibleActiveTabForChrome()

        let context = dragController.context
        let groupContext = groupDragController.context
        // External preview only applies when no in-window drag is active.
        let externalPreview = (context == nil && groupContext == nil) ? externalDragPreview : nil

        // Resolve pinned-zone drag parameters.
        let pinnedExcluded: Set<Int> = (context?.sourceContainerType == .pinned)
            ? sourceExclusionSet(for: context)
            : []
        let pinnedGap = (context?.targetContainerType == .pinned)
            ? context?.targetIndex
            : (externalPreview?.zone == .pinned ? externalPreview?.index : nil)

        // Resolve normal-zone drag parameters. Whole-group drag takes
        // priority — it's mutually exclusive with single-tab drag at
        // the controller level (entry points come from different
        // mouseDown sources), and uses excludedGroupRange + slice-wide
        // gap rather than single-tab semantics.
        let normalExcluded: Int?
        let normalExcludedSet: Set<Int>
        let normalExcludedRange: ClosedRange<Int>?
        let normalGap: Int?
        let normalGapW: CGFloat?
        if let gctx = groupContext {
            normalExcluded = nil
            normalExcludedSet = []
            let r = gctx.sourceRange
            // Three visual modes during whole-group drag:
            //   .external / .tearOff: cursor left this source strip.
            //     Slice "leaves" — exclude its footprint so other tabs
            //     slide left to close the gap. No destination gap to
            //     reserve in THIS strip (the slot lives in the target
            //     strip's externalDragPreview / nowhere for tear-off).
            //   .local + targetIndex in source range: no-op slot —
            //     leave natural layout, transform alone lifts the
            //     slice with the cursor.
            //   .local + targetIndex outside source range: excluded
            //     footprint + slice-wide gap at targetIndex.
            let isOutsideSource: Bool = {
                switch gctx.pendingDropAction {
                case .external, .tearOff, .rejected: return true
                case .local: return false
                }
            }()
            if isOutsideSource {
                normalExcludedRange = r.isEmpty ? nil : r.lowerBound...(r.upperBound - 1)
                normalGap = nil
                normalGapW = nil
            } else {
                let inSlice = gctx.targetIndex >= r.lowerBound && gctx.targetIndex <= r.upperBound
                if inSlice {
                    normalExcludedRange = nil
                    normalGap = nil
                    normalGapW = nil
                } else {
                    normalExcludedRange = r.isEmpty ? nil : r.lowerBound...(r.upperBound - 1)
                    normalGap = gctx.targetIndex
                    normalGapW = gctx.initialSliceWidth
                }
            }
        } else {
            normalExcluded = (context?.sourceContainerType == .normal) ? context?.sourceIndex : nil
            normalExcludedSet = (context?.sourceContainerType == .normal)
                ? sourceExclusionSet(for: context)
                : []
            normalExcludedRange = nil
            normalGap = (context?.targetContainerType == .normal)
                ? context?.targetIndex
                : (externalPreview?.zone == .normal ? externalPreview?.index : nil)
            // Pinned source: the dragged tab's own width is the narrow pinned
            // width, but in the normal zone the reserved slot must match a
            // normal tab — use the normal average so the make-way gap matches
            // the drop result (and the in-drag gap from
            // dragControllerDidUpdateLayout).
            let dragSlotPerTab: CGFloat?
            if context?.sourceContainerType == .pinned, let dt = context?.draggingTab {
                dragSlotPerTab = averageNormalTabWidth(excluding: dt)
            } else {
                dragSlotPerTab = context?.draggedTabWidth
            }
            // One slot even for a split pair — it re-merges into a single
            // cell on drop, matching the cross-window preview's sizing.
            normalGapW = (context?.targetContainerType == .normal)
                ? dragSlotPerTab
                : (externalPreview?.zone == .normal ? externalPreview?.gapWidth : nil)
        }

        let pinnedSplitCollapse = pinnedSplitCollapseInfo()
        let normalSplitCollapse = normalSplitCollapseInfo()

        // Layout-pass dispatch. Three states:
        //   1. Active whole-group drag (`groupContext != nil`):
        //      wrap frame assignment in NSAnimationContext so the
        //      non-dragged tabs' make-way reflow animates (0.18s,
        //      parallel to single-tab drag's
        //      `dragControllerDidUpdateLayout` path). The chip's own
        //      transform is set inside `setDisableActions(true)` so
        //      it tracks the cursor without a 0.18s lag.
        //   2. Settling after drop / cancel (`groupDragSettling`):
        //      `animateGroupDragSettle` already queued an animated
        //      frame + transform reset. Don't run a competing layout
        //      pass here — it would assign frames / reset transforms
        //      INSTANTLY and cancel the in-flight animation.
        //   3. Idle: original instant assignment, matches pre-existing
        //      layout triggers (resize, scroll, data-change paths
        //      wrapped separately by `performLayout(...)`).
        let runLayoutPasses = { [self] in
            updateLayoutOnly(
                container: pinnedContainer,
                viewPool: pinnedTabViews,
                tabs: pinnedTabs,
                activeTab: activeTab,
                isPinned: true,
                excludedIndices: pinnedExcluded,
                gapIndex: pinnedGap,
                pinnedSplitCollapsedIndices: pinnedSplitCollapse.collapsedIndices,
                pinnedSplitWideIndices: pinnedSplitCollapse.wideIndices
            )
            updateLayoutOnly(
                container: normalContainer,
                viewPool: normalTabViews,
                tabs: normalTabs,
                activeTab: activeTab,
                isPinned: false,
                excludedIndex: normalExcluded,
                excludedGroupRange: normalExcludedRange,
                excludedIndices: normalExcludedSet,
                gapIndex: normalGap,
                gapWidth: normalGapW,
                pinnedSplitCollapsedIndices: normalSplitCollapse.collapsedIndices,
                pinnedSplitWideIndices: normalSplitCollapse.wideIndices
            )
        }

        if groupContext != nil {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .default)
                ctx.allowsImplicitAnimation = true
                runLayoutPasses()
            }
            // Chip transform — instant, even though the surrounding
            // layout was in an animation block.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyGroupDragTransforms(context: groupContext)
            CATransaction.commit()
        } else if groupDragSettling {
            // In-flight settle animation owns frames AND transforms;
            // do nothing here.
        } else {
            runLayoutPasses()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyGroupDragTransforms(context: nil)
            CATransaction.commit()
        }

        onLayoutChanged?()
    }

    /// Sets `layer.transform` on the dragged group's chip + member
    /// views to the current mouse delta, and resets all other chip /
    /// normal-tab transforms to identity. Also raises the dragged
    /// views' `zPosition` so they render above the rest of the strip
    /// while drag is active.
    private func applyGroupDragTransforms(context: TabGroupDragContext?) {
        let identity = CATransform3DIdentity
        if let ctx = context {
            // Subtract the relayout-induced shift so the chip's visible
            // position stays under the cursor at the user's grab point.
            // See `TabGroupDragContext.chipPositionShift`.
            let deltaX = ctx.currentMouseLocation.x - ctx.initialMouseLocation.x
                       - ctx.chipPositionShift
            let translation = CATransform3DMakeTranslation(deltaX, 0, 0)
            let memberSet = Set(ctx.memberTabIds)
            let token = ctx.draggingChipToken
            let shouldTransformMembers = !ctx.isCollapsedAtDragStart

            for tab in browserState.normalTabs {
                guard let view = normalTabViews[tab.uniqueId] else { continue }
                if shouldTransformMembers && memberSet.contains(tab.guid) {
                    view.layer?.transform = translation
                    view.layer?.zPosition = 200
                } else {
                    view.layer?.transform = identity
                    view.layer?.zPosition = 10
                }
            }
            for (t, chip) in chipViews {
                if t == token {
                    chip.layer?.transform = translation
                    chip.layer?.zPosition = 200
                } else {
                    chip.layer?.transform = identity
                    chip.layer?.zPosition = 50
                }
            }
        } else {
            // No active group drag — reset any leftover transforms.
            for (_, view) in normalTabViews {
                view.layer?.transform = identity
                view.layer?.zPosition = 10
            }
            for (_, chip) in chipViews {
                chip.layer?.transform = identity
                chip.layer?.zPosition = 50
            }
        }
    }

    /// Returns the given tab's frame in `coordView`'s coordinate space, or nil
    /// if the tab should not contribute an active-tab gap (pinned, not shown,
    /// or being dragged over the pinned zone). The caller picks which tab to
    /// query — the content border passes the *visible* controller's tab,
    /// which can lag behind `browserState.focusingTab` during the
    /// deferred-first-paint switch path.
    ///
    /// During this tab's own drag the source view is hidden in favor of a drag
    /// proxy in `dragOverlay`, and the proxy gets restyled to match whichever
    /// zone it currently hovers over. The gap follows the same rule: it tracks
    /// the proxy's live frame while the proxy is over the normal zone, and
    /// disappears while the proxy crosses into the pinned zone — regardless
    /// of which zone the drag started from. Pinned tabs in their resting
    /// position never get a gap.
    /// Geometric envelope for one visible tab group on the strip, in
    /// `coordView` coordinates. Used by
    /// `WebContentContainerViewController` to draw a single unified
    /// colored path per group (chip-edge → horizontal underline →
    /// active tab outline (if applicable) → horizontal underline →
    /// last-tab edge), which avoids the perpendicular seam that two
    /// separate band+stroke shapes produce at the active tab's
    /// inverse-curve apex.
    ///
    /// Collapsed groups are omitted: the chip is still rendered on
    /// the strip but the group has no member-tab run, so there is no
    /// underline to draw.
    struct GroupGeometry {
        let token: String
        let leftX: CGFloat
        let rightX: CGFloat
        let containsActive: Bool
    }

    /// `activeTab` is the tab whose outline should be carved into the
    /// path (typically `currentWebContentController.associatedTab` —
    /// the *visible* tab — rather than `browserState.focusingTab`, to
    /// stay aligned with the unified content-border outline during the
    /// deferred-first-paint switch path).
    func groupGeometries(in coordView: NSView, activeTab: Tab?) -> [GroupGeometry] {
        let runs = currentGroupRuns()
        let normalTabs = browserState.normalTabs
        let activeIdx = normalTabs.firstIndex {
            isTabActive($0, activeTab: activeTab)
        }

        // While a drag is signaling leave-from-this-group (leading or
        // trailing edge cursor gate), pretend the dragged tab is no
        // longer in the group for boundary-path purposes:
        //
        //  • drop it from `containsActive` so the active-tab outline
        //    carving doesn't extend the colored path out to the
        //    floating proxy at the cursor;
        //  • when it was the run's last member, anchor the path to
        //    the previous visible member instead of the proxy frame.
        //
        // The geometric `outsideRange` leave is not detected here —
        // the drag controller hasn't yet computed it; we only have
        // the cursor-gated tokens. That's fine: at cursor positions
        // far enough to trigger geometric leave the cursor has
        // already crossed the trailing edge, so trailing leave is
        // also active, and this branch fires.
        let dragCtx = dragController.context
        // The single-tab drag has visually left the source strip when
        // the cursor is outside this strip's bounds. In that state
        // `updateSingleTabFloatingDragPreview` has already set the
        // in-strip proxy view's alpha to 0 and shown the floating
        // drag image; but the proxy's frame keeps tracking the cursor
        // in source-strip coords. Any geometry path keying off the
        // proxy frame — bottom line rightX extension, active-tab
        // outline carve — would then chase the cursor out of the
        // strip and render lines floating in empty space. Treat the
        // dragged tab as fully "gone" from its source group in that
        // state, mirroring how whole-group cross-window drag short-
        // circuits the run entirely (line 521-527).
        //
        // Note: `pendingDropAction` is NOT a reliable signal here —
        // it's only computed at drag-end (`handleTabDragEnd` line
        // 2454). During the drag it stays nil. The drag boundary
        // check is the same gate `updateSingleTabFloatingDragPreview`
        // uses to swap proxy/panel visuals, so visual and geometry
        // stay in sync by construction.
        let singleTabDragLeavingSource: Bool = {
            guard dragCtx != nil, let screenPoint = lastDragScreenPoint else { return false }
            return !isInsideDragBoundary(screenPoint)
        }()
        let leaveTokenForActive: String? = {
            guard let ctx = dragCtx, let activeIdx else { return nil }
            guard tabId(for: ctx.draggingTab) == tabId(for: normalTabs[activeIdx]) else { return nil }
            if let t = ctx.targetGroupForLeadingLeave { return t }
            if let t = ctx.targetGroupForTrailingLeave { return t }
            // Cross-window/tear-off: force-leave the dragged tab's
            // own group so the active outline doesn't try to carve
            // around the proxy frame at the cursor.
            if singleTabDragLeavingSource, let t = ctx.draggingTab.groupToken { return t }
            return nil
        }()

        // Symmetric to leave: detect when the active tab is the
        // dragged tab AND it's *about to join* a foreign group T,
        // so the colored boundary path can carve around the floating
        // proxy. Without this, an ungrouped active tab approaching
        // T appears with no group-color outline during drag — the
        // boundary stops at z.maxX and the proxy floats with only
        // its plain active outline, even though release would put
        // it in T. The carve gives the user a visible "this tab
        // will be in T" cue before release.
        //
        // Auto-join sources (mirrored from `dragControllerDidEndDrag`):
        //   • leadingJoin token (drop at lowerBound, gap-after-chip).
        //   • trailingJoin token (drop at upperBound+1, ≥1/3 cover z).
        //   • sandwich: drop strictly inside T's run — checked per-
        //     run below since it depends on run.range.
        let activeIsDraggedForeign: Bool = {
            guard let ctx = dragCtx else { return false }
            // Match by active identity, not by normalTabs index: a dragged
            // pinned tab that is the active tab isn't in normalTabs (activeIdx
            // is nil), yet it can still be joining a group, and its outline
            // must be carved into the boundary path.
            return isTabActive(ctx.draggingTab, activeTab: activeTab)
        }()

        var result: [GroupGeometry] = []
        for run in runs where !run.isCollapsed {
            guard let chip = chipViews[run.token],
                  chip.superview != nil,
                  run.range.upperBound < normalTabs.count else { continue }

            // Whole-group cross-window / tear-off: the slice is
            // visually "leaving" this strip (chip + members are
            // alpha=0 by `setSourceGroupVisualsHidden`, sourceRange
            // is excluded so other tabs slid into those slots).
            // Skip emitting geometry for this run entirely — its
            // underline would otherwise land at the run's drag-start
            // coordinates (now occupied by unrelated tabs that slid
            // left), painting a colored line under the wrong tabs.
            if let gctx = groupDragController.context,
               gctx.draggingChipToken == run.token {
                switch gctx.pendingDropAction {
                case .external, .tearOff, .rejected: continue
                case .local: break
                }
            }

            let leavePending: Bool = {
                guard let ctx = dragCtx else { return false }
                return ctx.targetGroupForLeadingLeave == run.token
                    || ctx.targetGroupForTrailingLeave == run.token
            }()

            // Single-member group whose lone member is leaving:
            // skip emitting a GroupGeometry entirely. The
            // underline can't anchor on a real `z` (the only
            // member is the dragged tab itself, whose frame stays
            // pinned at the source slot because applyLayout skips
            // the dragged tab) — falling through to the normal
            // path would leave the line spanning the empty source
            // slot. With no geometry the layer gets cleaned up
            // and the chip stands alone, matching the post-leave
            // group state.
            if leavePending,
               run.range.lowerBound == run.range.upperBound,
               let ctx = dragCtx,
               tabId(for: normalTabs[run.range.upperBound]) == tabId(for: ctx.draggingTab) {
                continue
            }

            // Pick the visible last member: when the dragged tab is
            // the run's last member AND a leave is pending, fall
            // back to the member before it (the one z) so the path
            // ends at z.maxX rather than the proxy's cursor frame.
            //
            // Split-pair normalization: `normalSplitCollapseInfo`
            // gives the LOWER-index pane the wide merged frame and
            // the HIGHER-index pane a `.zero` frame (the layout
            // engine treats the second pane as excluded). When a
            // run ends at the collapsed pane, `lastTabView.frame`
            // is zero-width and `lastFrame.maxX` lands at the
            // primary's leading edge instead of the merged bar's
            // trailing edge — the underline visually stops short of
            // the split. Step back to the wide partner so the path
            // anchors on the merged frame.
            let lastIdx: Int = {
                var idx = run.range.upperBound
                if leavePending,
                   let ctx = dragCtx,
                   tabId(for: normalTabs[idx]) == tabId(for: ctx.draggingTab) {
                    idx = max(run.range.lowerBound, idx - 1)
                }
                if idx > run.range.lowerBound,
                   let view = normalTabViews[tabId(for: normalTabs[idx])],
                   view.frame.width == 0,
                   let prevView = normalTabViews[tabId(for: normalTabs[idx - 1])],
                   prevView.frame.width > 0 {
                    idx -= 1
                }
                return idx
            }()
            let lastTab = normalTabs[lastIdx]
            guard let lastTabView = normalTabViews[tabId(for: lastTab)],
                  lastTabView.superview != nil else { continue }
            let chipFrame = chip.convert(chip.bounds, to: coordView)
            let lastFrame = lastTabView.convert(lastTabView.bounds, to: coordView)

            // Active-in-run:
            //   - Existing membership: run.range.contains(activeIdx).
            //     Flips false when the active tab IS the dragged tab
            //     AND it's leaving this run.
            //   - About to join (active = dragged, foreign T): when
            //     auto-join would fire on release. Three sources:
            //       a) ctx.targetGroupForLeadingJoin == run.token
            //       b) ctx.targetGroupForTrailingJoin == run.token
            //       c) sandwich: ctx.targetIndex strictly inside
            //          run.range (lowerBound < idx <= upperBound),
            //          with D's groupToken != run.token. Auto-joins
            //          via post-move neighbors at commit; we mirror
            //          that intent here so the visual carving leads
            //          the commit by one tick.
            let activeIsLeavingThisRun = (leaveTokenForActive == run.token)
            let activeIsJoiningThisRun: Bool = {
                guard activeIsDraggedForeign, let ctx = dragCtx else { return false }
                if ctx.targetGroupForLeadingJoin == run.token { return true }
                if ctx.targetGroupForTrailingJoin == run.token { return true }
                // Sandwich heuristic: drop slot strictly inside T's
                // run AND D not already in T's group.
                if ctx.draggingTab.groupToken != run.token,
                   ctx.targetIndex > run.range.lowerBound,
                   ctx.targetIndex <= run.range.upperBound {
                    return true
                }
                return false
            }()
            // activeIsJoiningThisRun must hold even when activeIdx is nil: a
            // dragged active pinned tab isn't in normalTabs but still joins.
            let containsActive: Bool = {
                if let activeIdx,
                   run.range.contains(activeIdx),
                   !activeIsLeavingThisRun {
                    return true
                }
                return activeIsJoiningThisRun
            }()

            // Trailing-edge JOIN visual: extend the run's rightX
            // past z to include the drop slot when this run is the
            // current trailing-join target. Without this, the
            // colored boundary stops at z.maxX while the drop slot
            // (where the foreign tab would land if released) sits
            // visibly outside the boundary — the commit would then
            // surprise the user by adding the tab to T despite the
            // visual saying otherwise. We extend to the next non-T
            // tab's drag-state minX (= drop slot's right edge);
            // when the run sits at the strip's tail, fall back to
            // `lastFrame.maxX + idealTabWidth` as the slot width.
            //
            // Sources: same-window drag (dragCtx.targetGroupForTrailingJoin)
            // OR cross-window external preview whose resolved intent
            // is trailingJoin on this run (joinRunToken matches AND
            // index == run.upperBound + 1). See spec §4.2.
            let externalTrailingJoinPending =
                (externalDragPreview?.joinRunToken == run.token)
                && (externalDragPreview?.index == run.range.upperBound + 1)
            let trailingJoinPending =
                (dragCtx?.targetGroupForTrailingJoin == run.token)
                || externalTrailingJoinPending
            let rightX: CGFloat = {
                guard trailingJoinPending else { return lastFrame.maxX }
                let nextIdx = run.range.upperBound + 1
                if nextIdx < normalTabs.count {
                    let nextTab = normalTabs[nextIdx]
                    if let nextView = normalTabViews[tabId(for: nextTab)],
                       nextView.superview != nil {
                        let nextFrame = nextView.convert(nextView.bounds, to: coordView)
                        if nextFrame.minX > lastFrame.maxX {
                            return nextFrame.minX
                        }
                    }
                }
                return lastFrame.maxX + TabStripMetrics.Tab.idealWidth
            }()

            // Stretch leftX/rightX to encompass the dragged proxy
            // when, on release, D would end up as a member of this
            // run. Two sources:
            //
            //   • Own group (D.groupToken == run.token): D is
            //     already a member; "in run" means NOT leaving via
            //     leading/trailing edge.
            //   • Foreign group join: leadingJoin token,
            //     trailingJoin token, or sandwich heuristic (drop
            //     slot strictly inside this run AND D not already
            //     in it).
            //
            // For active D the WCC path builder already extends to
            // proxy via `min`/`max` with `af` (the active frame is
            // the proxy frame for the dragged tab). The leftX/
            // rightX widening here is redundant for that path but
            // harmless. For non-active D, `af` is some OTHER tab
            // (or unused) and the path builder won't reach the
            // proxy on its own — the widening is what makes the
            // underline run beneath the floating proxy.
            //
            // The padding by `edgeInset` cancels out WCC's inset
            // (`leftX + inset` and `rightX - inset`), so the line
            // truly reaches the proxy's left/right edges instead
            // of being clipped 5pt short.
            let dWillBeInThisRun: Bool = {
                guard let ctx = dragCtx else { return false }
                if ctx.draggingTab.groupToken == run.token {
                    // Cross-window/tear-off counts as leaving for
                    // proxy-extension purposes — the proxy is
                    // outside the strip and dragging the underline
                    // out with it would be wrong.
                    let leavingThisRun = (ctx.targetGroupForLeadingLeave == run.token
                        || ctx.targetGroupForTrailingLeave == run.token
                        || singleTabDragLeavingSource)
                    return !leavingThisRun
                }
                if ctx.targetGroupForLeadingJoin == run.token { return true }
                if ctx.targetGroupForTrailingJoin == run.token { return true }
                if ctx.targetIndex > run.range.lowerBound,
                   ctx.targetIndex <= run.range.upperBound {
                    return true
                }
                return false
            }()

            var finalLeftX = chipFrame.minX
            var finalRightX = rightX
            if dWillBeInThisRun,
               let proxyView = draggingProxyView,
               proxyView.superview != nil {
                let proxyFrame = proxyView.convert(proxyView.bounds, to: coordView)
                let edgeInset = TabStripMetrics.Tab.inverseCornerRadius - 3
                finalLeftX = min(finalLeftX, proxyFrame.minX - edgeInset)
                finalRightX = max(finalRightX, proxyFrame.maxX + edgeInset)
            }

            // Whole-group drag: the dragged group's chip + members are
            // visually translated via `layer.transform`, but their
            // `.frame` (and therefore `chip.convert(...)` / view.convert
            // result) stays at the drag-start position. Offset the
            // geometry by the same deltaX so the underline + active-
            // tab outline path follow the cursor.
            let groupDragDeltaX: CGFloat = {
                guard let gctx = groupDragController.context,
                      gctx.draggingChipToken == run.token else { return 0 }
                // When the cursor is outside this source strip, the
                // slice's chip + members are alpha=0 and a floating
                // chip preview is shown elsewhere. The underline /
                // active-tab outline must NOT follow the cursor in
                // that case — they'd visibly run off to the side of
                // the strip while the slice itself is invisible.
                switch gctx.pendingDropAction {
                case .external, .tearOff, .rejected: return 0
                case .local:
                    return gctx.currentMouseLocation.x - gctx.initialMouseLocation.x
                }
            }()

            result.append(GroupGeometry(
                token: run.token,
                leftX: finalLeftX + groupDragDeltaX,
                rightX: finalRightX + groupDragDeltaX,
                containsActive: containsActive
            ))
        }
        return result
    }

    func tabFrame(for tab: Tab?, in coordView: NSView) -> CGRect? {
        guard let tab else { return nil }
        // Match by uniqueId, not reference: WebContentViewController.associatedTab
        // can hold a different Tab instance than browserState.pinnedTabs /
        // dragController.context.draggingTab while representing the same
        // logical tab (different objects, same guidInLocalDB / guid).
        let id = tabId(for: tab)
        if let context = dragController.context, tabId(for: context.draggingTab) == id {
            // Cross-window / tear-off: when the cursor leaves the
            // source strip, `updateSingleTabFloatingDragPreview` has
            // hidden the in-strip proxy (alpha=0) and shown a floating
            // NSPanel image at the cursor. The proxy's `.frame` keeps
            // tracking the cursor in source-strip coords, so returning
            // it here would let WCC paint the active-tab outline at
            // cursor coordinates — drifting outside the strip with
            // the floating image. Suppress with the same gate the
            // float-preview helper uses; symmetric with the whole-
            // group branch below.
            //
            // `pendingDropAction` is unreliable mid-drag (only set at
            // drag-end); use `isInsideDragBoundary` directly.
            if let screenPoint = lastDragScreenPoint,
               !isInsideDragBoundary(screenPoint) {
                return nil
            }
            guard context.targetContainerType != .pinned,
                  let proxy = draggingProxyView,
                  proxy.superview != nil else {
                return nil
            }
            return proxy.convert(proxy.bounds, to: coordView)
        }
        // During a split-pair drag the partner's source view sits at .zero
        // because the layout engine excludes it. Use the lifted partner proxy
        // so the content-border gap follows the active sibling correctly.
        if dragController.context != nil,
           let siblingSource = draggingSiblingSourceView,
           let siblingProxy = draggingSiblingProxyView,
           siblingProxy.superview != nil,
           let siblingTabId = normalTabViews.first(where: { $0.value === siblingSource })?.key,
           siblingTabId == id {
            return siblingProxy.convert(siblingProxy.bounds, to: coordView)
        }
        let isPinned = browserState.pinnedTabs.contains(where: { tabId(for: $0) == id })
        guard !isPinned,
              let view = normalTabViews[id],
              view.superview != nil else {
            return nil
        }
        // Split-pair higher-index pane: its own view is the `.zero`
        // collapsed placeholder, so its converted frame is zero-width
        // at the origin. Substitute the wide host partner's frame so
        // callers like the WCC active-tab outline carve around the
        // merged cell. Without this the carve targets (0, 0, 0, 0) and
        // the group's outer border + underline collapse to a glitched
        // straight line on every reverse-panes.
        if view.frame.width == 0,
           let group = browserState.splitGroup(forTabId: tab.guid),
           !group.isPinned,
           let partnerId = group.partnerTabId(of: tab.guid),
           let partnerTab = browserState.normalTabs.first(where: { $0.guid == partnerId }),
           let partnerView = normalTabViews[tabId(for: partnerTab)],
           partnerView.superview != nil,
           partnerView.frame.width > 0 {
            // Delegate instead of converting `partnerView` directly: during a
            // merged-cell drag the host partner is the dragging tab, whose
            // source view stays parked at its drag-start frame (alpha = 0)
            // while the proxy follows the cursor. Re-entering tabFrame lets
            // the partner's drag-proxy and group-drag branches resolve the
            // live frame. Bounded: the width > 0 guard above keeps the
            // partner out of this placeholder branch.
            return tabFrame(for: partnerTab, in: coordView)
        }
        let frame = view.convert(view.bounds, to: coordView)
        // Whole-group drag: members are visually translated via
        // `layer.transform`; their `.frame` (= the convert result)
        // stays at drag-start. Mirror the offset so consumers like
        // the active-tab outline carving track the cursor. When the
        // cursor left the source strip (.external / .tearOff), the
        // slice is alpha=0 AND its drag-start slot is now occupied by
        // other tabs that slid left (excludedGroupRange shrinks the
        // strip) — emitting any frame here would paint the active
        // outline over an unrelated tab. Return nil to suppress.
        if let gctx = groupDragController.context,
           gctx.memberTabIds.contains(tab.guid) {
            switch gctx.pendingDropAction {
            case .external, .tearOff, .rejected:
                return nil
            case .local:
                let deltaX = gctx.currentMouseLocation.x - gctx.initialMouseLocation.x
                return frame.offsetBy(dx: deltaX, dy: 0)
            }
        }
        return frame
    }

    // MARK: - Mouse Tracking
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        unlockLayoutIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The cached NTP / internal-page default-favicon TIFF was
        // rasterized against the prior appearance; invalidate it so
        // the next mosaic refresh re-rasterizes with the new variant.
        // Then repush mosaic data to every live chip so currently-
        // collapsed groups update immediately.
        cachedPhiDefaultFaviconMosaicData = nil
        for token in chipViews.keys {
            refreshChipMosaic(for: token)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let visibleWidth = normalContainer.bounds.width
        if lastContentWidth <= visibleWidth {
            super.scrollWheel(with: event)
            return
        }

        let maxScroll = max(0, lastContentWidth - visibleWidth)
        let delta = event.scrollingDeltaX
        var newOffset = currentScrollOffset - delta
        newOffset = max(0, min(newOffset, maxScroll))
        if newOffset != currentScrollOffset {
            currentScrollOffset = newOffset
            self.hoveredTabIndex = nil
            for view in normalTabViews.values {
                view.resetHoverState()
            }
            performLayout(context: .none) // Avoid animations.
        } else {
            super.scrollWheel(with: event)
        }
    }

    private func scrollToMakeTabVisible(_ tab: Tab) {
        guard let view = normalTabViews[tab.uniqueId] else { return }
        let originalFrame = view.frame.offsetBy(dx: currentScrollOffset, dy: 0)
        let visibleWidth = normalContainer.bounds.width
        var newOffset = currentScrollOffset
        // Extra scroll margin revealed beyond the current viewport.
        let extraPadding: CGFloat = 120
        if originalFrame.minX - extraPadding < currentScrollOffset {
            // Decrease the offset to scroll content right.
            newOffset = originalFrame.minX - extraPadding
        } else if originalFrame.maxX + extraPadding > currentScrollOffset + visibleWidth {
            // Increase the offset to scroll content left.
            newOffset = originalFrame.maxX - visibleWidth + extraPadding
        }
        let maxScroll = max(0, lastContentWidth - visibleWidth)
        newOffset = max(0, min(newOffset, maxScroll))
        if abs(newOffset - currentScrollOffset) > 1 {
            currentScrollOffset = newOffset
            self.hoveredTabIndex = nil
            for view in normalTabViews.values {
                view.resetHoverState()
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                self.rebindData()
            }
        }
    }

    private func unlockLayoutIfNeeded() {
        guard isLayoutLocked else { return }
        isLayoutLocked = false
        lockedTabWidth = nil
        // Recompute layout after the scroll offset changes.
        performLayout(context: .stateChanged)
    }

    private func rebindData() {
        let pinnedTabs = browserState.pinnedTabs
        let normalTabs = browserState.normalTabs
        let activeTab = visibleActiveTabForChrome()
        let pinnedSplitCollapse = pinnedSplitCollapseInfo()
        let normalSplitCollapse = normalSplitCollapseInfo()

        updateContainer(
            container: pinnedContainer,
            viewPool: &pinnedTabViews,
            tabs: pinnedTabs,
            activeTab: activeTab,
            isPinned: true,
            pinnedSplitPartners: pinnedSplitCollapse.partners,
            pinnedSplitCollapsedIndices: pinnedSplitCollapse.collapsedIndices,
            pinnedSplitWideIndices: pinnedSplitCollapse.wideIndices
        )

        updateContainer(
            container: normalContainer,
            viewPool: &normalTabViews,
            tabs: normalTabs,
            activeTab: activeTab,
            isPinned: false,
            pinnedSplitPartners: normalSplitCollapse.partners,
            pinnedSplitCollapsedIndices: normalSplitCollapse.collapsedIndices,
            pinnedSplitWideIndices: normalSplitCollapse.wideIndices
        )

        // scroll-driven and animation-driven repositioning enters here without
        // going through layout(); fire the same notification so the content
        // outer border tracks the active tab's new x.
        onLayoutChanged?()
    }

    private func visibleActiveTabForChrome() -> Tab? {
        browserState.groupOverviewState == nil ? browserState.focusingTab : nil
    }

    // MARK: - Data Binding
    func setActive(_ active: Bool) {
        if active {
            activate()
        } else {
            deactivate()
        }
    }

    private func activate() {
        guard isActive == false else {
            syncVisibleState()
            return
        }
        isActive = true
        bindData()
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        cancellables.removeAll()
        groupChangeCancellables.removeAll()
        collapsedGroupFaviconCancellables.removeAll()
        clearInactiveContent()
    }

    private func syncVisibleState() {
        let pinnedTabs = browserState.pinnedTabs
        let normalTabs = browserState.normalTabs
        let activeTab = visibleActiveTabForChrome()

        pinnedContainer.layer?.backgroundColor = pinnedTabs.isEmpty
            ? NSColor.clear.cgColor
            : NSColor(resource: .sidebarTabHovered).cgColor
        previousNormalTabCount = normalTabs.count
        previousTrailingNormalTabId = normalTabs.last?.guid
        isLayoutLocked = false
        lockedTabWidth = nil

        performLayout(context: .dataChanged) {
            if let activeTab {
                self.scrollToMakeTabVisible(activeTab)
            }
        }
        needsLayout = true
    }

    private func clearInactiveContent() {
        clearExternalPreviewTarget()
        clearExternalDragPreview()
        clearDraggingPresentation(using: nil)

        pinnedTabViews.values.forEach { $0.removeFromSuperview() }
        normalTabViews.values.forEach { $0.removeFromSuperview() }
        separatorViews.forEach { $0.removeFromSuperview() }
        pinnedTabViews.removeAll()
        normalTabViews.removeAll()
        separatorViews.removeAll()
        chipViews.values.forEach { $0.removeFromSuperview() }
        chipViews.removeAll()
        chipRightSeparatorViews.values.forEach { $0.removeFromSuperview() }
        chipRightSeparatorViews.removeAll()
        chipFullWidths.removeAll()
        hoveredChipToken = nil
        collapsedGroupFaviconCancellables.removeAll()

        hoveredTabIndex = nil
        currentScrollOffset = 0
        lastContentWidth = 0
        previousNormalTabCount = 0
        previousTrailingNormalTabId = nil
        isLayoutLocked = false
        lockedTabWidth = nil
        pendingDropAction = nil
        externalDragPreview = nil

        pinnedContainer.layer?.backgroundColor = NSColor.clear.cgColor
        pinnedContainer.snp.updateConstraints { make in
            make.width.equalTo(0)
        }
        newTabButton.frame = .zero
        needsLayout = true
    }

    private func bindData() {
        cancellables.removeAll()
        browserState.$pinnedTabs
            .combineLatest(browserState.$normalTabs, browserState.$focusingTab)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pinnedTabs, normalTabs, activeTab in
                guard let self = self else { return }
                guard self.isActive else { return }

                if pinnedTabs.isEmpty {
                    self.pinnedContainer.layer?.backgroundColor = NSColor.clear.cgColor
                } else {
                    self.pinnedContainer.layer?.backgroundColor = NSColor(resource: .sidebarTabHovered).cgColor
                }

                let isTabClosed = normalTabs.count < self.previousNormalTabCount
                let trailingTabClosed = isTabClosed
                    && (self.previousTrailingNormalTabId.map { previousLast in
                        !normalTabs.contains { $0.guid == previousLast }
                    } ?? false)
                self.previousNormalTabCount = normalTabs.count
                self.previousTrailingNormalTabId = normalTabs.last?.guid

                if isTabClosed && self.isMouseInside() {
                    if trailingTabClosed {
                        // Trailing close: reflow IS the continuation
                        // affordance here. Width-constrained tabs fill the
                        // container, so re-allocating parks the new
                        // trailing tab's close button back at the fixed
                        // right-edge position under the cursor, while a
                        // frozen layout would leave the cursor past the
                        // content end. Also ends a running locked session
                        // the moment the cursor slot becomes the trailing
                        // tab, snapping straight to the final layout.
                        self.isLayoutLocked = false
                        self.lockedTabWidth = nil
                    } else {
                        self.lockLayoutIfNeeded()
                    }
                }

                // Refresh chip widths for any group whose member count
                // affects the rendered title (auto-named groups always;
                // user-named groups only the count badge).
                for token in self.browserState.groups.keys {
                    self.refreshChipWidth(for: token)
                }
                self.rebuildCollapsedGroupFaviconSubscriptions()

                self.performLayout(context: .dataChanged) {
                    if let activeTab = activeTab {
                        self.scrollToMakeTabVisible(activeTab)
                    }
                }
                self.needsLayout = true
            }
            .store(in: &cancellables)

        browserState.$multiSelection
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isActive else { return }
                self.performLayout(context: .dataChanged)
                self.needsLayout = true
            }
            .store(in: &cancellables)

        browserState.$groupOverviewState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, self.isActive else { return }
                self.selectedGroupTokenForOverviewPlaceholder = state?.groupToken
                self.performLayout(context: .dataChanged)
                self.needsLayout = true
            }
            .store(in: &cancellables)

        // Splits don't change the tab list, so the combineLatest above never
        // fires when a split is created/dissolved. Re-render on split changes
        // so the merged-bar appearance updates.
        browserState.$splits
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isActive else { return }
                self.performLayout(context: .dataChanged)
                self.needsLayout = true
            }
            .store(in: &cancellables)

        // Group dictionary itself: handle add / remove / visual changes.
        browserState.$groups
            .receive(on: DispatchQueue.main)
            .sink { [weak self] groups in
                guard let self = self, self.isActive else { return }
                // Drop chip-width entries for vanished groups.
                let liveTokens = Set(groups.keys)
                self.chipFullWidths = self.chipFullWidths.filter { liveTokens.contains($0.key) }
                // Refresh widths for surviving groups (color / title /
                // collapsed flag may have flipped).
                for token in groups.keys {
                    self.refreshChipWidth(for: token)
                }
                self.rebuildCollapsedGroupFaviconSubscriptions()
                self.rebuildGroupChangeSubscriptions(groups: groups)
                self.performLayout(context: .dataChanged)
            }
            .store(in: &cancellables)
    }

    /// (Re)subscribes to each `WebContentGroupInfo.objectWillChange` so
    /// the strip relays out when membership flips (`Tab.groupToken` set
    /// via `handleTabJoinedGroup` / `handleTabLeftGroup`) or when a
    /// group's title / color / collapsed flag mutates without a
    /// `groups` dictionary reassignment (`handleTabGroupVisualDataChanged`).
    /// Without this, the chip's auto-name count badge and underline
    /// color stay stale until the next unrelated relayout.
    private func rebuildGroupChangeSubscriptions(groups: [String: WebContentGroupInfo]) {
        WebContentGroupInfo.reconcileSubscriptions(
            groups: groups,
            cancellables: &groupChangeCancellables
        ) { [weak self] token in
            guard let self = self, self.isActive else { return }
            self.refreshChipWidth(for: token)
            self.rebuildCollapsedGroupFaviconSubscriptions()
            self.performLayout(context: .dataChanged)
        }
    }

    /// Reconciles the per-collapsed-group favicon subscription set
    /// so the mosaic refreshes when any of the first ≤4 members'
    /// `liveFaviconData` / `cachedFaviconData` / `url` changes.
    ///
    /// Called whenever the set of collapsed groups or their first-
    /// ≤4 members can change: from `bindData`'s tab-list sink and
    /// from the `$groups` sink. Idempotent; safe to call on every
    /// data event.
    ///
    /// Subscriptions are torn down when:
    ///   • the group is expanded (drops from the collapsed set),
    ///   • the group is destroyed (drops from `groups`),
    ///   • the membership change reduces the observed members.
    ///
    /// Why `$url` is observed alongside the favicon publishers:
    /// when a member navigates from a real site to NTP (or vice
    /// versa) Chromium may keep the previous page's favicon bytes
    /// in `liveFaviconData` momentarily, so the favicon publisher
    /// alone wouldn't fire. The mosaic relies on
    /// `collectMosaicFaviconData` to re-evaluate the URL through
    /// `FaviconConfiguration.shouldUseDefaultFavicon`, so we must
    /// trigger that re-evaluation whenever `tab.url` changes.
    ///
    /// Tradeoff: observing `$url` fires `refreshChipMosaic` on
    /// every navigation in a member tab (anchor jumps, pushState,
    /// redirects), not only when the NTP boundary is crossed. The
    /// refresh is cheap — `[Data: CGImage]` cache hits on stable
    /// favicon bytes — so we accept the spurious fires rather than
    /// add per-tab "previous shouldUseDefaultFavicon state"
    /// bookkeeping. Revisit if profiling shows hotness.
    private func rebuildCollapsedGroupFaviconSubscriptions() {
        // Snapshot the current "collapsed + first ≤4 members" view.
        var desired: [String: [Tab]] = [:]
        for (token, info) in browserState.groups where info.isCollapsed {
            let members = browserState.normalTabs
                .filter { $0.groupToken == token }
                .prefix(4)
            desired[token] = Array(members)
        }

        // Drop subscriptions for groups no longer in the desired set.
        let liveTokens = Set(desired.keys)
        collapsedGroupFaviconCancellables = collapsedGroupFaviconCancellables
            .filter { liveTokens.contains($0.key) }

        // Replace subscription sets wholesale per token. We don't
        // try to diff member-by-member: the cost of a fresh
        // subscribe-on-publisher is negligible vs. the bookkeeping
        // complexity of preserving partial sets across membership
        // shuffles.
        for (token, tabs) in desired {
            var subs = Set<AnyCancellable>()
            for tab in tabs {
                tab.$liveFaviconData
                    .combineLatest(tab.$cachedFaviconData, tab.$url)
                    .dropFirst()  // chip already has the current values
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _, _, _ in
                        self?.refreshChipMosaic(for: token)
                    }
                    .store(in: &subs)
            }
            collapsedGroupFaviconCancellables[token] = subs
        }
    }

    /// Pushes the current member favicons into the chip's mosaic
    /// without going through the full configure path. Called by
    /// the favicon-data subscription sink (Step 6.1) when a
    /// member's `liveFaviconData` / `cachedFaviconData` / `url`
    /// changes.
    private func refreshChipMosaic(for token: String) {
        guard let chip = chipViews[token],
              chip.superview != nil,
              let group = browserState.groups[token],
              group.isCollapsed else { return }
        chip.updateMosaic(memberFavicons: collectMosaicFaviconData(for: token))
    }

    /// Pinned-split collapse info for the strip's pinned section:
    /// - `collapsedIndices`: indices in `browserState.pinnedTabs` of the
    ///   `.second` pane of each pinned split. The layout engine drops their
    ///   slot; the view is force-hidden.
    /// - `wideIndices`: indices of the `.first` panes. The layout engine
    ///   gives them double width so two favicons fit comfortably.
    /// - `partners`: `firstPaneUniqueId → partner Tab`, consumed when
    ///   building `TabRenderData` so the cell knows it should render two
    ///   favicons side-by-side.
    /// Non-pinned split collapse info for the strip's normal section.
    /// Mirrors `pinnedSplitCollapseInfo` but iterates `normalTabs` and the
    /// non-pinned `SplitGroup`s. Both ungrouped and in-group splits collapse
    /// — when a pair sits inside a tab group, the group's chip still covers
    /// the original index range; only the second pane's slot drops out of
    /// layout (excluded) while the first pane widens to host both favicons.
    private func normalSplitCollapseInfo() -> (collapsedIndices: Set<Int>, wideIndices: Set<Int>, partners: [String: Tab]) {
        var collapsed = Set<Int>()
        var wide = Set<Int>()
        var partners: [String: Tab] = [:]
        let normal = browserState.normalTabs
        guard !normal.isEmpty else { return ([], [], [:]) }
        var consumed = Set<Int>()
        for (idx, tab) in normal.enumerated() {
            guard !consumed.contains(tab.guid),
                  let group = browserState.splitGroup(forTabId: tab.guid),
                  !group.isPinned,
                  let partnerId = group.partnerTabId(of: tab.guid),
                  let partner = normal.first(where: { $0.guid == partnerId }),
                  // Both panes must share the same group affiliation (both
                  // ungrouped, or both in the same tab group) — a split
                  // straddling a group boundary stays as two cells.
                  tab.groupToken == partner.groupToken,
                  let partnerIdx = normal.firstIndex(where: { $0.guid == partnerId }),
                  abs(idx - partnerIdx) == 1 else {
                continue
            }
            let (firstIdx, secondIdx) = idx < partnerIdx ? (idx, partnerIdx) : (partnerIdx, idx)
            partners[normal[firstIdx].uniqueId] = normal[secondIdx]
            wide.insert(firstIdx)
            collapsed.insert(secondIdx)
            consumed.insert(tab.guid)
            consumed.insert(partnerId)
        }
        return (collapsed, wide, partners)
    }

    private func pinnedSplitCollapseInfo() -> (collapsedIndices: Set<Int>, wideIndices: Set<Int>, partners: [String: Tab]) {
        var collapsed = Set<Int>()
        var wide = Set<Int>()
        var partners: [String: Tab] = [:]
        let pinned = browserState.pinnedTabs
        guard !pinned.isEmpty else { return ([], [], [:]) }
        var consumed = Set<String>()
        for (idx, tab) in pinned.enumerated() {
            guard let dbGuid = tab.guidInLocalDB, !consumed.contains(dbGuid) else { continue }

            var partnerDbGuid: String?
            if let liveTab = browserState.tabs.first(where: { $0.guidInLocalDB == dbGuid }),
               let group = browserState.splits.first(where: { $0.isPinned && $0.contains(tabId: liveTab.guid) }) {
                guard let partnerLiveId = group.partnerTabId(of: liveTab.guid) else { continue }
                partnerDbGuid = browserState.tabs.first(where: { $0.guid == partnerLiveId })?.guidInLocalDB
            }
            if partnerDbGuid == nil, let persisted = tab.splitPartnerGuid, !persisted.isEmpty {
                partnerDbGuid = persisted
            }
            guard let resolvedPartnerDbGuid = partnerDbGuid,
                  let partnerIdx = pinned.firstIndex(where: { $0.guidInLocalDB == resolvedPartnerDbGuid }) else {
                continue
            }
            let (firstIdx, secondIdx) = idx < partnerIdx ? (idx, partnerIdx) : (partnerIdx, idx)
            partners[pinned[firstIdx].uniqueId] = pinned[secondIdx]
            wide.insert(firstIdx)
            collapsed.insert(secondIdx)
            consumed.insert(dbGuid)
            consumed.insert(resolvedPartnerDbGuid)
        }
        return (collapsed, wide, partners)
    }

    /// Compute split-pair position + active-group flag for the tab strip's
    /// renderer. Returns (nil, false) when the tab is not in a split.
    ///
    /// Handles two cases:
    /// 1. Normal tabs — `tab.guid` is a live Chromium id; look up split and
    ///    position via the standard `normalTabs`-ordered helper.
    /// 2. Pinned-tab records — `tab.guid` is a synthetic placeholder (the
    ///    record is built from a `TabDataModel`, not the live tab in `tabs`).
    ///    Resolve to the live Chromium tab via `guidInLocalDB`, look up the
    ///    `SplitGroup` by that guid, and compute the pair position from
    ///    `pinnedTabs` ordering so the merged-bar styling kicks in for the
    ///    horizontal pinned section.
    private func splitRenderInfo(for tab: Tab) -> (position: SplitPairPosition?, groupActive: Bool) {
        if let group = browserState.splitGroup(forTabId: tab.guid) {
            return (browserState.splitPairPosition(forTabId: tab.guid),
                    browserState.isSplitGroupActive(group))
        }
        guard let dbGuid = tab.guidInLocalDB, !dbGuid.isEmpty,
              let liveTab = browserState.tabs.first(where: { $0.guidInLocalDB == dbGuid }),
              let group = browserState.splitGroup(forTabId: liveTab.guid),
              group.isPinned else {
            return (nil, false)
        }
        guard let partnerLiveId = group.partnerTabId(of: liveTab.guid),
              let partnerLive = browserState.tabs.first(where: { $0.guid == partnerLiveId }),
              let partnerDbGuid = partnerLive.guidInLocalDB,
              let myIdx = browserState.pinnedTabs.firstIndex(where: { $0.guidInLocalDB == dbGuid }),
              let partnerIdx = browserState.pinnedTabs.firstIndex(where: { $0.guidInLocalDB == partnerDbGuid }),
              abs(myIdx - partnerIdx) == 1 else {
            return (nil, false)
        }
        let position: SplitPairPosition = myIdx < partnerIdx ? .first : .second
        return (position, browserState.isSplitGroupActive(group))
    }

    private func isMouseInside() -> Bool {
        guard let window = window else { return false }
        let mouseLocation = window.mouseLocationOutsideOfEventStream
        let locationInView = convert(mouseLocation, from: nil)
        return bounds.contains(locationInView)
    }

    private func lockLayoutIfNeeded() {
        guard !isLayoutLocked else { return }
        guard normalTabViews.count > 1 else { return }

        // Lock whenever the strip is width-constrained, i.e. some tab sits
        // below the ideal width. In that whole band widths come from
        // container allocation (available / count), so a close
        // redistributes the freed space and every close button drifts away
        // from the cursor — not just in the compressed (< activeMinWidth)
        // band. At full ideal width a close moves no widths (the next
        // close button slides under the cursor by itself), so no lock is
        // needed.
        //
        // Sample the MINIMUM qualifying width: the engine keeps
        // active ≥ inactive and split merged cells at ~2× a single cell,
        // so the minimum is always a plain inactive tab's width — an
        // arbitrary dictionary hit could capture the active tab (or a
        // merged cell) and broadcast its wider value to every inactive
        // tab, visibly expanding the strip the moment the lock engages.
        // `frame != .zero` filters out collapsed-group members: they're
        // sized to zero by `layoutNormalWithGroups`, not because the strip
        // is compressed, but because the group is collapsed — they
        // shouldn't be treated as "narrow inactive tab" evidence. Without
        // the filter, the heuristic captures `lockedTabWidth = 0` and
        // freezes a degenerate layout where every non-active cell
        // collapses to width 0 (visually a clump of overlapping favicons,
        // sticky until mouse exits the strip).
        let idealWidth = TabStripMetrics.Tab.idealWidth
        let inactiveTabWidth = normalTabViews.values
            .filter { $0.frame != .zero && $0.frame.width < idealWidth }
            .map(\.frame.width)
            .min()

        // At full ideal width there is nothing to freeze.
        if let width = inactiveTabWidth {
            lockedTabWidth = width
            isLayoutLocked = true
        }
    }

    /// Updates one container by coordinating layout, view-pool, and apply phases.
    ///
    /// The three phases stay separate so animation and drag behavior can evolve
    /// independently without mixing lifecycle and frame application concerns.
    private func updateContainer(
        container: NSView?,
        viewPool: inout [String: TabItemView],
        tabs: [Tab],
        activeTab: Tab?,
        isPinned: Bool,
        excludedIndex: Int? = nil,
        excludedGroupRange: ClosedRange<Int>? = nil,
        excludedIndices: Set<Int> = [],
        gapIndex: Int? = nil,
        gapWidth: CGFloat? = nil,
        pinnedSplitPartners: [String: Tab] = [:],
        pinnedSplitCollapsedIndices: Set<Int> = [],
        pinnedSplitWideIndices: Set<Int> = []
    ) {
        guard let container = container else { return }

        // The layout engine already collapses positions for any index in
        // `excludedTabIndices`; route the collapsed split-second-pane indices
        // through it so their slots disappear instead of leaving a gap.
        let combinedExcluded = excludedIndices.union(pinnedSplitCollapsedIndices)

        let layoutOutput = calculateLayout(
            containerWidth: container.bounds.width,
            tabs: tabs,
            activeTab: activeTab,
            isPinned: isPinned,
            excludedIndex: excludedIndex,
            excludedGroupRange: excludedGroupRange,
            excludedIndices: combinedExcluded,
            wideIndices: pinnedSplitWideIndices,
            gapIndex: gapIndex,
            gapWidth: gapWidth
        )

        updateViewPool(
            container: container,
            viewPool: &viewPool,
            tabs: tabs,
            activeTab: activeTab,
            isPinned: isPinned,
            pinnedSplitPartners: pinnedSplitPartners,
            pinnedSplitCollapsedIndices: pinnedSplitCollapsedIndices
        )

        applyLayout(
            container: container,
            viewPool: viewPool,
            layoutOutput: layoutOutput,
            tabs: tabs,
            activeTab: activeTab,
            isPinned: isPinned
        )
    }

    /// Pure layout calculation with no side effects.
    ///
    /// - Note: This function is intentionally side-effect free and unit-testable.
    ///
    /// - Extension Point [Drag]: Additional drag-only parameters can be threaded
    ///   through here, such as excluding the dragged tab or reserving a gap.
    private func calculateLayout(
        containerWidth: CGFloat,
        tabs: [Tab],
        activeTab: Tab?,
        isPinned: Bool,
        excludedIndex: Int? = nil,
        excludedGroupRange: ClosedRange<Int>? = nil,
        excludedIndices: Set<Int> = [],
        wideIndices: Set<Int> = [],
        gapIndex: Int? = nil,
        gapWidth: CGFloat? = nil
    ) -> TabStripLayoutOutput {
        if isPinned {
            return TabStripLayoutEngine.layoutPinned(
                tabCount: tabs.count,
                excludedTabIndices: excludedIndices,
                wideTabIndices: wideIndices,
                gapAtIndex: gapIndex
            )
        }

        let activeIndex = tabs.firstIndex { isTabActive($0, activeTab: activeTab) }
        // A merged split cell hosts two panes, so when it is the active
        // cell its protected width must clear the split compact cutoff —
        // at the single-tab minimum it would fall back to the two-favicon
        // compact rendering and lose the per-pane close buttons.
        let activeTabWidth = (activeIndex.map { wideIndices.contains($0) } ?? false)
            ? TabStripMetrics.Tab.activeSplitMinWidth
            : TabStripMetrics.Tab.activeMinWidth
        let runs = currentGroupRuns()
        // `gapBeforeRunStartChip` is a per-layout hint the engine
        // uses ONLY when the gap actually lands at a run's
        // lowerBound. Sources that should force before-chip:
        //   • THIS strip is itself running a whole-group drag (same-
        //     window slice slots in front of foreign chip).
        //   • THIS strip has an external drop preview AND the
        //     resolved intent is OUTSIDE (joinRunToken == nil).
        //     JOIN intent (joinRunToken != nil) wants the gap on
        //     the OTHER side of chip (inside the group), so the
        //     flag must stay false. See spec §4.1.
        //   • Single-tab same-window drag's cursor-half heuristic.
        let externalIsOutsideIntent = (externalDragPreview != nil)
            && (externalDragPreview?.joinRunToken == nil)
        let gapBeforeRunStartChip = !isPinned && (
            (groupDragController.context != nil)
            || externalIsOutsideIntent
            || (dragController.context?.gapBeforeRunStartChip ?? false)
        )
        let input = TabStripLayoutInput(
            containerWidth: containerWidth,
            tabCount: tabs.count,
            activeTabIndex: activeIndex,
            spacing: TabStripMetrics.Tab.spacing,
            idealTabWidth: TabStripMetrics.Tab.idealWidth,
            minTabWidth: TabStripMetrics.Tab.minWidth,
            activeTabWidth: activeTabWidth,
            tabHeight: TabStripMetrics.Strip.tabHeight,
            excludedTabIndex: excludedIndex,
            excludedGroupRange: isPinned ? nil : excludedGroupRange,
            excludedTabIndices: excludedIndices,
            wideTabIndices: wideIndices,
            gapAtIndex: gapIndex,
            gapWidth: gapWidth,
            groupRuns: isPinned ? [] : runs,
            chipFullWidths: isPinned ? [:] : chipFullWidths,
            gapBeforeRunStartChip: gapBeforeRunStartChip,
            lockedInactiveTabWidth: isLayoutLocked ? lockedTabWidth : nil
        )
        return TabStripLayoutEngine.layoutNormal(input: input)
    }

    /// Updates the view pool by creating, reusing, configuring, and removing views.
    ///
    /// - Note: This handles lifecycle and data binding only, not positioning.
    ///
    /// - Extension Point [Drag]: Drag mode may skip updating the dragged tab or
    ///   move it into a dedicated drag layer.
    private func updateViewPool(
        container: NSView,
        viewPool: inout [String: TabItemView],
        tabs: [Tab],
        activeTab: Tab?,
        isPinned: Bool,
        pinnedSplitPartners: [String: Tab] = [:],
        pinnedSplitCollapsedIndices: Set<Int> = []
    ) {
        var nextViews: [String: TabItemView] = [:]

        for (index, tab) in tabs.enumerated() {
            let id = tabId(for: tab)
            let view: TabItemView

            if let existingView = viewPool[id] {
                view = existingView
            } else {
                view = TabItemView()
                container.addSubview(view)
                
                if index > 0 {
                    let prevTab = tabs[index - 1]
                    if let prevView = nextViews[prevTab.uniqueId] {
                        view.frame = CGRect(x: prevView.frame.maxX, y: prevView.frame.origin.y, width: 0, height: prevView.frame.height)
                    }
                } else {
                    view.frame = CGRect(x: 0, y: 0, width: 0, height: TabStripMetrics.Strip.tabHeight)
                }
                view.alphaValue = 0
            }

            let splitInfo = splitRenderInfo(for: tab)
            // The first pane of a pinned split now stands alone — its cell
            // visually represents both panes (two favicons in one cell). The
            // factory clears the paired-bar styling for that case so the
            // background renders as one complete rounded pinned cell.
            let render: TabSplitRender = {
                if let partner = pinnedSplitPartners[id] {
                    return .pinnedMerged(partner: partner)
                }
                return .standalone(position: splitInfo.position,
                                   isGroupActive: splitInfo.groupActive)
            }()
            // Merged-cell active highlight follows EITHER pane being focused
            // — clicking the right half flips activeTab to the partner, and
            // the merged cell still represents both panes.
            let cellIsActive = isTabActive(tab, activeTab: activeTab)
                || (render.pinnedMergedPartner.map { isTabActive($0, activeTab: activeTab) } ?? false)
            let renderData = TabRenderData(
                id: id,
                title: tab.title,
                url: tab.url ?? "",
                isActive: cellIsActive,
                isPinned: isPinned,
                isMultiSelected: browserState.multiSelection.contains(tab.guid),
                splitPairPosition: render.position,
                isSplitGroupActive: render.isGroupActive,
                pinnedSplitPartner: render.pinnedMergedPartner,
                sourceTab: tab
            )
            view.configure(with: renderData)

            let isDraggingSourceView = dragController.context.map {
                tabId(for: $0.draggingTab) == id
            } ?? false
            // Collapsed split-second-pane: keep the view fully transparent so
            // its layer (which does not mask to bounds) can't bleed into the
            // neighbouring cell even though `applyLayout` will zero its frame.
            //
            // For split members, snap the alpha (no implicit animation) so a
            // pane swap (reverse) doesn't cross-fade the wide-host between the
            // two TabItemViews — that read as the merged cell briefly vanishing
            // and reappearing because both views animate through alpha 0.
            let isSplitMember = pinnedSplitCollapsedIndices.contains(index)
                || pinnedSplitPartners[id] != nil
            if isDraggingSourceView {
                view.alphaValue = 0
            } else if pinnedSplitCollapsedIndices.contains(index) {
                if isSplitMember {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    view.alphaValue = 0
                    CATransaction.commit()
                } else {
                    view.alphaValue = 0
                }
            } else if view.alphaValue < 1.0 {
                if isSplitMember {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    view.alphaValue = 1.0
                    CATransaction.commit()
                } else {
                    view.animator().alphaValue = 1.0
                }
            }

            view.onDragStart = { [weak self] event in
                self?.handleTabDragStart(event: event, tab: tab, isPinned: isPinned, index: index, frame: view.frame)
            }

            view.onDragUpdate = { [weak self] event in
                self?.handleTabDragUpdate(event: event)
            }

            view.onDragEnd = { [weak self] in
                self?.handleTabDragEnd()
            }

            view.onSelect = { [weak self, weak tab] flags in
                guard let self, let tab else { return }
                // Cmd+click toggles multi-selection; owner handles pinned/active.
                if flags.contains(.command),
                   self.browserState.toggleMultiSelection(for: tab) {
                    return
                } else {
                    if self.browserState.multiSelection.isActive {
                        self.browserState.clearMultiSelection()
                    }
                }
                self.handleTabSelection(tab: tab)
            }
            // Split-merged cells: the right favicon represents the partner
            // pane; clicking that half should focus the partner instead of
            // the primary tab. Wire the secondary callback to the partner
            // tab captured at configure time.
            view.onSecondarySelect = { [weak self, weak partner = pinnedSplitPartners[id]] in
                self?.handleTabSelection(tab: partner)
            }
            if !isPinned {
                let capturedIndex = index
                view.onHoverChanged = { [weak self] isHovered in
                    guard let self = self else { return }
                    self.hoveredTabIndex = isHovered ? capturedIndex : nil
                    // Mirror `performLayout`'s split-secondary exclusion so
                    // the recomputed separator positions match the frames
                    // actually on screen.
                    let splitCollapse = self.normalSplitCollapseInfo()
                    let output = self.calculateLayout(
                        containerWidth: self.normalContainer.bounds.width,
                        tabs: self.browserState.normalTabs,
                        activeTab: self.visibleActiveTabForChrome(),
                        isPinned: false,
                        excludedIndices: splitCollapse.collapsedIndices,
                        wideIndices: splitCollapse.wideIndices
                    )
                    // Re-render separators because hover state affects visibility.
                    self.updateSeparators(
                        in: self.normalContainer,
                        xPositions: output.separatorXPositions,
                        tabs: self.browserState.normalTabs,
                        activeTab: self.visibleActiveTabForChrome()
                    )
                    self.updateChipRightSeparators(
                        in: self.normalContainer,
                        chipFrames: output.chipFrames,
                        tabs: self.browserState.normalTabs,
                        activeTab: self.visibleActiveTabForChrome()
                    )
                }
            }

            // Stamp the UI-test query surface. The collapsed second pane of a
            // split (it merges into its partner's cell) and the transparent
            // drag-source stand-in must not count as separate tab cells.
            let axVisible = !isDraggingSourceView
                && !pinnedSplitCollapsedIndices.contains(index)
            view.configureAccessibility(
                identifier: isPinned
                    ? TabItemView.pinnedAccessibilityIdentifier
                    : TabItemView.normalAccessibilityIdentifier,
                title: tab.title,
                visible: axVisible,
                isSplitPair: pinnedSplitPartners[id] != nil)

            nextViews[id] = view
        }

        for (id, view) in viewPool where nextViews[id] == nil {
            view.removeFromSuperview()
        }

        viewPool = nextViews
    }

    /// Applies computed frames to the existing views.
    ///
    /// - Note: This updates positions only; creation and binding happen elsewhere.
    ///
    /// - Extension Point [Animation]: Frame application can be wrapped in custom
    ///   animation contexts for add, close, or reorder transitions.
    /// - Extension Point [Drag]: The dragged tab may be skipped here because it
    ///   follows the pointer in a separate presentation layer.
    private func applyLayout(
        container: NSView,
        viewPool: [String: TabItemView],
        layoutOutput: TabStripLayoutOutput,
        tabs: [Tab],
        activeTab: Tab?,
        isPinned: Bool
    ) {
        if !isPinned {
            lastContentWidth = layoutOutput.totalContentWidth
            let visibleWidth = container.bounds.width
            let maxScroll = max(0, lastContentWidth - visibleWidth)
            if currentScrollOffset > maxScroll {
                currentScrollOffset = maxScroll
            }
        }
        let draggingTab = dragController.context?.draggingTab
        // Expanded group members keep their drag-start frames while
        // `applyGroupDragTransforms` drives cursor follow. Collapsed
        // groups draw chip-only, so members should remain in the
        // normal collapsed `.zero` layout.
        let draggedGroupMemberIds: Set<Int> = {
            guard !isPinned,
                  let groupContext = groupDragController.context,
                  !groupContext.isCollapsedAtDragStart else {
                return []
            }
            return Set(groupContext.memberTabIds)
        }()

        for (index, tab) in tabs.enumerated() {
            let id = tabId(for: tab)
            guard let view = viewPool[id] else { continue }

            if draggingTab != nil && tab === draggingTab {
                continue
            }
            if draggedGroupMemberIds.contains(tab.guid) {
                continue
            }

            if index < layoutOutput.tabFrames.count {
                var frame = layoutOutput.tabFrames[index]
                // A .zero frame is the layout engine's "excluded" placeholder.
                // Most .zero cases (collapsed group members, pinned-split
                // collapsed second pane, dragged-tab placeholder) must zero
                // out the view's frame so a stale frame from the previous
                // layout doesn't ghost on top of the active layout.
                //
                // The split-pair drag sibling is the one exception: keep its
                // source view in place so its proxy can return to a meaningful
                // frame on drop without snapping to (0, 0). startDragging
                // already hid alpha there.
                // Split-pair swap (reverse panes) flips which view holds the
                // wide merged cell — without snapping, both views animate
                // through alpha 0 / partial frames inside the .dataChanged
                // animation group, which reads as the cell disappearing and
                // reappearing. Snap frame + alpha for split members so the
                // swap is instantaneous.
                let isSplitMember = browserState.splitGroup(forTabId: tab.guid) != nil
                if frame == .zero {
                    if view === draggingSiblingSourceView {
                        continue
                    }
                    if isSplitMember {
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        view.frame = .zero
                        view.alphaValue = 0
                        CATransaction.commit()
                    } else {
                        view.frame = .zero
                        view.alphaValue = 0
                    }
                    continue
                }
                if !isPinned {
                    frame.origin.x -= currentScrollOffset
                }
                if isSplitMember {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    view.frame = frame
                    view.alphaValue = 1
                    CATransaction.commit()
                } else {
                    view.frame = frame
                    view.alphaValue = 1
                }
            }
        }

        if isPinned {
            let newWidth = layoutOutput.totalContentWidth
            // Avoid recursive layout caused by constraint updates.
            if abs(pinnedContainer.frame.width - newWidth) > 0.1 {
                pinnedContainer.snp.updateConstraints { make in
                    make.width.equalTo(newWidth)
                }
            }
        } else {
            let flowX = layoutOutput.newTabButtonFrame.origin.x - currentScrollOffset
            let stickyX = container.bounds.width
                        - layoutOutput.newTabButtonFrame.width
                        - TabStripMetrics.NewTabButton.insets.right

            let finalX = min(flowX, stickyX)

            newTabButton.frame = layoutOutput.newTabButtonFrame
            newTabButton.frame.origin.x = finalX + normalContainer.frame.origin.x
            newTabButton.layer?.zPosition = 200
            updateSeparators(
                in: container,
                xPositions: layoutOutput.separatorXPositions,
                tabs: tabs,
                activeTab: activeTab
            )
        }
        if !isPinned {
            lastContentWidth = layoutOutput.totalContentWidth
            updateNormalContainerMask()
        }

        // Chip placement runs only for the normal zone. Per-group
        // colored boundary paths (underline + active outline) are
        // drawn in WCC, not here.
        if !isPinned {
            applyChipPlacements(
                container: container,
                chipFrames: layoutOutput.chipFrames
            )
            updateChipRightSeparators(
                in: container,
                chipFrames: layoutOutput.chipFrames,
                tabs: tabs,
                activeTab: activeTab
            )
        }
    }

    /// Allocates / reuses chip views, sets their frames (with scroll
    /// offset baked in), and tears down stale entries. Called from
    /// `applyLayout` for the normal zone only.
    private func applyChipPlacements(
        container: NSView,
        chipFrames: [String: ChipPlacement]
    ) {
        for (token, placement) in chipFrames {
            let chip: TabGroupChipView
            if let existing = chipViews[token] {
                chip = existing
            } else {
                chip = TabGroupChipView()
                container.addSubview(chip)
                chipViews[token] = chip
                chip.onClick = { [weak self] tappedToken in
                    self?.handleChipClick(token: tappedToken)
                }
                chip.onCollapseToggle = { [weak self] tappedToken in
                    self?.handleChipCollapseToggle(token: tappedToken)
                }
                chip.onHoverChanged = { [weak self] hoveredToken, hovered in
                    guard let self else { return }
                    self.hoveredChipToken = hovered ? hoveredToken : nil
                    // Re-render both separator pools so the chip's left
                    // separator (in `separatorViews`) and right separator
                    // (in `chipRightSeparatorViews`) react to the change.
                    // Mirror `performLayout`'s split-secondary exclusion so
                    // the recomputed positions match the on-screen frames.
                    let splitCollapse = self.normalSplitCollapseInfo()
                    let output = self.calculateLayout(
                        containerWidth: self.normalContainer.bounds.width,
                        tabs: self.browserState.normalTabs,
                        activeTab: self.visibleActiveTabForChrome(),
                        isPinned: false,
                        excludedIndices: splitCollapse.collapsedIndices,
                        wideIndices: splitCollapse.wideIndices
                    )
                    self.updateSeparators(
                        in: self.normalContainer,
                        xPositions: output.separatorXPositions,
                        tabs: self.browserState.normalTabs,
                        activeTab: self.visibleActiveTabForChrome()
                    )
                    self.updateChipRightSeparators(
                        in: self.normalContainer,
                        chipFrames: output.chipFrames,
                        tabs: self.browserState.normalTabs,
                        activeTab: self.visibleActiveTabForChrome()
                    )
                }
                chip.onMenuRequest = { [weak self] tappedToken in
                    self?.makeChipMenu(token: tappedToken)
                }
                chip.onDragStart = { [weak self] tappedToken, winLoc in
                    guard let self else { return }
                    let local = self.convert(winLoc, from: nil)
                    self.updateDragScreenPoint(fromWindowPoint: winLoc)
                    // If a prior whole-group drag's settle animation is
                    // still in flight (drop happened in the last ~180ms),
                    // tear it down before doing anything else. Two
                    // reasons:
                    //   (a) `layout()`'s middle branch would otherwise
                    //       skip the snapshot's prerequisite layout pass
                    //       below — snapshot would read pre-collapse
                    //       chipView.frame and miscompute sliceWidth /
                    //       snap candidates.
                    //   (b) In-flight CA transform animations on the
                    //       prior dragged group's chip + member layers
                    //       would otherwise shadow this new drag's
                    //       `setDisableActions`-wrapped transform sets,
                    //       so the new chip wouldn't visibly track the
                    //       cursor until the stale animation ends.
                    self.cancelInFlightGroupDragSettle()
                    // If the dragged group is currently expanded,
                    // temp-collapse it visually for the duration of
                    // the drag. Must happen BEFORE startDragging so
                    // the snapshot's chipFrame / sliceWidth / snap
                    // candidates are computed against the post-collapse
                    // layout (sliceWidth = chipW, members .zero-width).
                    // Restored on drop/cancel via
                    // `releaseTemporaryCollapseIfNeeded`.
                    let wasExpanded = !(self.browserState.groups[tappedToken]?.isCollapsed ?? false)
                    if wasExpanded {
                        // Stash chip's pre-relayout metrics-space minX
                        // so the snapshot can compute chipPositionShift
                        // and override its chipFrame to the user-grabbed
                        // position.
                        self.chipPreCollapseMetricsMinXForDrag =
                            chip.frame.minX + self.currentScrollOffset

                        self.temporarilyCollapsedGroupTokenForDrag = tappedToken
                        self.refreshChipWidth(for: tappedToken)
                        // `refreshChipWidth` mutates `chipFullWidths`
                        // but does not invalidate layout, so
                        // `layoutSubtreeIfNeeded()` would no-op without
                        // this. Snapshot then reads pre-collapse
                        // chipView.frame and miscomputes sliceWidth.
                        self.needsLayout = true
                        self.layoutSubtreeIfNeeded()
                        AppLogDebug(
                            "[TAB_GROUPS][GROUP_DRAG] temporarilyCollapse " +
                            "token=\(tappedToken)"
                        )
                    }
                    let started = self.groupDragController.startDragging(
                        token: tappedToken, mouseLocation: local)
                    if started {
                        self.installGroupDragEscMonitor()
                    } else if wasExpanded {
                        // Snapshot vetoed the drag — undo the
                        // temp-collapse so the strip doesn't stay
                        // stuck in the wrong visual state.
                        self.temporarilyCollapsedGroupTokenForDrag = nil
                        self.refreshChipWidth(for: tappedToken)
                        self.needsLayout = true
                        AppLogDebug(
                            "[TAB_GROUPS][GROUP_DRAG] startDragging vetoed; " +
                            "undid temp-collapse token=\(tappedToken)"
                        )
                    }
                    // Defensive: snapshot consumes-and-clears the ivar
                    // on its happy path, but if `startDragging` returned
                    // early without calling snapshot (e.g., a live drag
                    // already had `context != nil`), the stale value
                    // would leak into the next drag.
                    self.chipPreCollapseMetricsMinXForDrag = nil
                }
                chip.onDrag = { [weak self] _, winLoc in
                    guard let self else { return }
                    let local = self.convert(winLoc, from: nil)
                    self.updateDragScreenPoint(fromWindowPoint: winLoc)
                    self.groupDragController.continueDragging(mouseLocation: local)
                    // Drive cross-window preview + floating chip image
                    // each frame, parallel to handleTabDragUpdate for
                    // single-tab drag.
                    if let screenPoint = self.lastDragScreenPoint {
                        self.updateFloatingDragPreview(screenPoint: screenPoint)
                        self.updateExternalPreviewTarget(screenPoint: screenPoint)
                    }
                }
                chip.onDragEnd = { [weak self] _, winLoc in
                    guard let self else { return }
                    let local = self.convert(winLoc, from: nil)
                    self.updateDragScreenPoint(fromWindowPoint: winLoc)
                    // Capture both the action snapshot (used to decide
                    // whether to restore alpha after endDragging) and
                    // the visual snapshot (token + member ids for the
                    // alpha restore call) BEFORE endDragging tears down
                    // the context.
                    let visualSnapshot = self.groupDragController.context.map {
                        (token: $0.draggingChipToken, memberIds: $0.memberTabIds)
                    }
                    let actionAtEnd = self.groupDragController.context?.pendingDropAction
                    self.groupDragController.endDragging(mouseLocation: local)
                    self.removeGroupDragEscMonitor()
                    self.hideFloatingDragPreview()
                    // Alpha restore policy:
                    //   .local                → restore (slice stays)
                    //   .rejected             → restore (target refused
                    //                            zone, slice stays in
                    //                            source)
                    //   .external / .tearOff  → DO NOT restore. Members
                    //                            are leaving this strip
                    //                            (cross-window or new
                    //                            window); Chromium's
                    //                            kRemoved events will
                    //                            drop them from
                    //                            `normalTabs` and the
                    //                            next layout will not
                    //                            include them.
                    //                            Restoring would flash
                    //                            them at their
                    //                            drag-start positions
                    //                            for one frame.
                    //   .none (context lost)  → restore defensively.
                    let shouldRestoreAlpha: Bool = {
                        switch actionAtEnd {
                        case .external, .tearOff: return false
                        case .local, .rejected, .none: return true
                        }
                    }()
                    if shouldRestoreAlpha, let snap = visualSnapshot {
                        self.restoreSourceGroupVisuals(token: snap.token, memberIds: snap.memberIds)
                    }
                    self.clearExternalPreviewTarget()
                }
            }
            guard let group = browserState.groups[token] else { continue }
            let memberCount = browserState.normalTabs
                .lazy.filter { $0.groupToken == token }.count
            chip.configure(
                token: token,
                color: group.color,
                displayTitle: group.displayTitle(memberCount: memberCount),
                memberCount: memberCount,
                hasUserSetTitle: group.hasUserSetTitle,
                isCollapsed: effectiveIsCollapsed(for: token),
                memberFavicons: collectMosaicFaviconData(for: token)
            )
            // The chip of the actively-dragged group keeps its
            // drag-start frame; `applyGroupDragTransforms` handles
            // cursor follow + zPosition. Skipping frame assignment
            // here avoids overwriting the visual position with the
            // layout engine's placeholder x (chip contributes no
            // width during whole-group drag).
            if groupDragController.context?.draggingChipToken == token {
                continue
            }
            var f = placement.frame
            f.origin.x -= currentScrollOffset
            chip.frame = f
            chip.layer?.zPosition = 50  // Above tab cells (10) and below drag overlay (999).
        }
        // Tear down chips for vanished groups.
        for (token, view) in chipViews where chipFrames[token] == nil {
            view.removeFromSuperview()
            chipViews.removeValue(forKey: token)
            if hoveredChipToken == token { hoveredChipToken = nil }
            if selectedGroupTokenForOverviewPlaceholder == token {
                selectedGroupTokenForOverviewPlaceholder = nil
            }
        }
        // Mirror teardown for chip-right separators.
        for (token, view) in chipRightSeparatorViews where chipFrames[token] == nil {
            view.removeFromSuperview()
            chipRightSeparatorViews.removeValue(forKey: token)
        }
        updateGroupChipSelectionState()
    }

    /// Renders the chip→right-neighbor separator for each visible chip.
    /// Hide rule mirrors `updateSeparators`: hide when the right
    /// neighbor (by tab index) is active or hovered. A nil
    /// `rightSeparatorX` on the placement means "no separator this
    /// pass" (chip at strip end, excluded during whole-group drag,
    /// or the neighbor itself is the drag-excluded tab); the view
    /// is hidden in that case.
    private func updateChipRightSeparators(
        in container: NSView,
        chipFrames: [String: ChipPlacement],
        tabs: [Tab],
        activeTab: Tab?
    ) {
        let sepSize = TabStripMetrics.Content.separatorSize
        let y = TabStripMetrics.Strip.bottomSpacing
              + (TabStripMetrics.Strip.tabHeight - sepSize.height) / 2.0
        let activeIndex = tabs.firstIndex { isTabActive($0, activeTab: activeTab) }

        for (token, placement) in chipFrames {
            let sep: NSView
            if let existing = chipRightSeparatorViews[token] {
                sep = existing
            } else {
                sep = NSView()
                sep.wantsLayer = true
                sep.phiLayer?.setBackgroundColor(TabStripMetrics.Content.separatorColor)
                container.addSubview(sep, positioned: .below, relativeTo: nil)
                chipRightSeparatorViews[token] = sep
            }
            guard let sepX = placement.rightSeparatorX,
                  let neighborIdx = placement.rightSeparatorNeighborIndex else {
                sep.isHidden = true
                continue
            }
            let finalX = (container === normalContainer) ? (sepX - currentScrollOffset) : sepX
            sep.frame = CGRect(x: finalX, y: y, width: sepSize.width, height: sepSize.height)
            let hideByActive = (activeIndex == neighborIdx)
            let hideByHover = (hoveredTabIndex == neighborIdx)
            // Hide the chip's own right separator when the chip itself is hovered.
            let hideByOwnChipHover = (hoveredChipToken == token)
            // Hide when the chip directly to the right is hovered — covers
            // adjacent-collapsed-groups (chipA's right separator = chipB's
            // left separator) and collapsed-then-expanded adjacency. The
            // `!= token` guard prevents double-firing for own hover, which
            // `hideByOwnChipHover` already covers.
            let neighborChipToken: String? = (neighborIdx < tabs.count)
                ? tabs[neighborIdx].groupToken
                : nil
            let hideByNeighborChipHover = (neighborChipToken != nil
                                           && neighborChipToken == hoveredChipToken
                                           && neighborChipToken != token)
            sep.isHidden = hideByActive || hideByHover || hideByOwnChipHover || hideByNeighborChipHover
        }
    }

    private func handleChipClick(token: String) {
        guard browserState.groups[token] != nil else { return }
        // A plain click while multi-selecting exits the selection
        if browserState.multiSelection.isActive {
            browserState.clearMultiSelection()
        }
        browserState.showGroupOverview(token: token)
        AppLogDebug(
            "[TAB_GROUPS][STRIP] chip overview windowId=\(browserState.windowId) " +
            "token=\(token)"
        )
    }

    private func handleChipCollapseToggle(token: String) {
        guard let group = browserState.groups[token] else { return }
        let next = !group.isCollapsed
        AppLogDebug(
            "[TAB_GROUPS][STRIP] chip collapse windowId=\(browserState.windowId) " +
            "token=\(token) collapsed=\(group.isCollapsed)->\(next)"
        )
        ChromiumLauncher.sharedInstance().bridge?.updateTabGroupCollapsed(
            withWindowId: Int64(browserState.windowId),
            tokenHex: token,
            isCollapsed: next
        )
    }

    private func updateGroupChipSelectionState() {
        for (token, chip) in chipViews {
            chip.setOverviewSelected(token == selectedGroupTokenForOverviewPlaceholder)
        }
    }

    @MainActor
    private func makeChipMenu(token: String) -> NSMenu? {
        guard let group = browserState.groups[token] else { return nil }
        let item = TabGroupSidebarItem(group: group, browserState: browserState)
        let menu = NSMenu()
        item.makeContextMenu(on: menu)
        guard !menu.items.isEmpty else { return nil }
        // NSMenuItem.target is weak. The local `item` would
        // deallocate as soon as this method returns, leaving every
        // menu entry with a nil target — AppKit then disables them
        // all. Anchor the helper's lifetime to the menu by stashing
        // it on the first item's representedObject (strongly held
        // by NSMenuItem, which is strongly held by NSMenu).
        menu.items.first?.representedObject = item
        return menu
    }

    private func performLayout(context: TabStripAnimationContext, completion: (() -> Void)? = nil) {
        TabStripAnimationHelper.performLayout(context, animations: { [weak self] in
            self?.rebindData()
        }, completion: completion)
    }

    private func updateSeparators(in container: NSView, xPositions: [CGFloat], tabs: [Tab], activeTab: Tab?) {
        // Ensure the separator pool matches the required count.
        while separatorViews.count < xPositions.count {
            let sep = NSView()
            sep.wantsLayer = true
            sep.phiLayer?.setBackgroundColor(TabStripMetrics.Content.separatorColor)
            // Keep separators below tabs so they never cover interactive content.
            container.addSubview(sep, positioned: .below, relativeTo: nil)
            separatorViews.append(sep)
        }

        while separatorViews.count > xPositions.count {
            separatorViews.removeLast().removeFromSuperview()
        }

        // Layout separators and decide which ones should be hidden.
        let sepSize = TabStripMetrics.Content.separatorSize
        let y = TabStripMetrics.Strip.bottomSpacing + (TabStripMetrics.Strip.tabHeight - sepSize.height) / 2.0
        let activeIndex = tabs.firstIndex { isTabActive($0, activeTab: activeTab) }

        // Split-secondary slots are zero-width with off-screen separators,
        // so the separator visually left of a tab can belong to an earlier
        // index (the pair host's right edge). Every left-side rule below
        // must use this mapping instead of the plain `idx - 1`.
        let splitCollapsedIndices = normalSplitCollapseInfo().collapsedIndices
        let leftSeparatorIndex: (Int) -> Int = { idx in
            TabStripLayoutEngine.visibleLeftSeparatorIndex(of: idx, skippingCollapsed: splitCollapsedIndices)
        }

        // Hovered chip's left-edge sits between tab[firstMember - 1] and the chip.
        // That tab's right separator (separator[firstMember - 1]) should hide.
        let hoveredChipFirstMemberIdx: Int? = {
            guard let token = hoveredChipToken else { return nil }
            return tabs.firstIndex { $0.groupToken == token }
        }()

        // True when tab[i] is the first visible member of an EXPANDED group.
        // The "hide left-adjacent separator" rule must NOT fire in this case:
        // a chip sits between tab[i-1] and tab[i], so separator[i-1] is the
        // chip's left separator (not directly adjacent to tab[i]). For
        // collapsed groups this check is unnecessary — their members are
        // zero-width with separators pre-hidden at x=-1000.
        let firstMemberOfExpandedGroup: (Int) -> Bool = { [weak self] idx in
            guard let self = self,
                  idx >= 0, idx < tabs.count,
                  let token = tabs[idx].groupToken,
                  let group = self.browserState.groups[token],
                  !group.isCollapsed else { return false }
            return tabs.firstIndex(where: { $0.groupToken == token }) == idx
        }

        for (index, x) in xPositions.enumerated() {
            let sep = separatorViews[index]
            // Separators only render in the normal container, but keep the check explicit.
            let finalX = (container === normalContainer) ? (x - currentScrollOffset) : x
            sep.frame = CGRect(x: finalX, y: y, width: sepSize.width, height: sepSize.height)

            // Hide separators adjacent to the active or hovered tab.
            var shouldHide = false

            if let activeIdx = activeIndex {
                if index == activeIdx { shouldHide = true }      // Separator on the tab's right side.
                if index == leftSeparatorIndex(activeIdx) && !firstMemberOfExpandedGroup(activeIdx) {
                    shouldHide = true  // Tab's left side (chip-between guard).
                }
            }
            if let hoveredIdx = hoveredTabIndex {
                if index == hoveredIdx { shouldHide = true }      // Separator on the tab's right side.
                if index == leftSeparatorIndex(hoveredIdx) && !firstMemberOfExpandedGroup(hoveredIdx) {
                    shouldHide = true  // Tab's left side (chip-between guard).
                }
            }
            if let firstMemberIdx = hoveredChipFirstMemberIdx,
               index == leftSeparatorIndex(firstMemberIdx) {
                shouldHide = true  // Separator on the hovered chip's left side.
            }

            sep.isHidden = shouldHide
        }
    }

    // MARK: - Helper Methods
    private func tabId(for tab: Tab) -> String {
        return tab.uniqueId
    }

    /// Effective collapsed state for `token` — folds the data-layer
    /// `BrowserState.groups[token].isCollapsed` together with the
    /// UI-only `temporarilyCollapsedGroupTokenForDrag` overlay. Every
    /// site that decides whether to render a group as collapsed
    /// (layout, chip configure, chip width measurement) should go
    /// through this so the overlay applies consistently.
    private func effectiveIsCollapsed(for token: String) -> Bool {
        let dataLayer = browserState.groups[token]?.isCollapsed ?? false
        return dataLayer || temporarilyCollapsedGroupTokenForDrag == token
    }

    /// Walks `browserState.normalTabs` and emits one `GroupRun` per
    /// maximal stretch of adjacent tabs sharing the same `groupToken`.
    /// Used both by the layout engine input and the drag-end auto-leave
    /// check, so both agree on group ranges within a single layout cycle.
    private func currentGroupRuns() -> [GroupRun] {
        let tabs = browserState.normalTabs
        var runs: [GroupRun] = []
        var i = 0
        while i < tabs.count {
            guard let token = tabs[i].groupToken else { i += 1; continue }
            var j = i
            while j + 1 < tabs.count && tabs[j + 1].groupToken == token {
                j += 1
            }
            let isCollapsed = effectiveIsCollapsed(for: token)
            runs.append(GroupRun(token: token, range: i...j, isCollapsed: isCollapsed))
            i = j + 1
        }
        #if DEBUG
        // Contiguity invariant: each group token should appear in at
        // most one run. A repeat means somewhere along the way a
        // group's members got split by an intruder tab — `applyLayout`
        // would render two chips for the same token, which is the
        // visible symptom of the invariant breaking.
        //
        // Log instead of asserting: the strip drag handler intentionally
        // produces transient `[member, ex-member(stale-token), member]`
        // arrangements between the move (`moveNormalTabLocally` publishes
        // `normalTabs` immediately) and the membership clear
        // (`applyOptimisticGroupMembership` re-publishes a moment later).
        // The next publish always restores contiguity; crashing on the
        // intermediate snapshot — which can be read by any synchronous
        // `currentGroupRuns()` caller chained off a Combine sink — is
        // a debug-only false positive. A warning still surfaces real
        // breakage (a state that never recovers shows up in the log
        // alongside the visible duplicate-chip artifact).
        var tokenCounts: [String: Int] = [:]
        for run in runs {
            tokenCounts[run.token, default: 0] += 1
        }
        for (token, count) in tokenCounts where count > 1 {
            let liveOrder = browserState.normalTabs.map { $0.guid }
            AppLogWarn(
                "[TabGroupDrag] group contiguity transiently broken: token=\(token) " +
                "appears in \(count) runs in normalTabs=\(liveOrder)"
            )
        }
        #endif
        return runs
    }

    /// TIFF-encoded bytes of `NSImage.phiDefaultFavicon`, cached
    /// per-appearance. `NSImage.phiDefaultFavicon` ships light + dark
    /// variants; rasterizing it bakes whichever variant resolved at
    /// generation time into static bytes. We cache one rasterization
    /// at a time and invalidate on `viewDidChangeEffectiveAppearance`
    /// so a theme switch repaints NTP / internal-page mosaic slots
    /// (regular NTP tab favicons re-render automatically because they
    /// host the dynamic `NSImage` directly).
    private var cachedPhiDefaultFaviconMosaicData: Data?

    private func phiDefaultFaviconMosaicData() -> Data? {
        if let cached = cachedPhiDefaultFaviconMosaicData {
            return cached
        }
        var data: Data?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            data = NSImage.phiDefaultFavicon.tiffRepresentation
        }
        cachedPhiDefaultFaviconMosaicData = data
        return data
    }

    /// Returns the favicon `Data?` for the first `min(memberCount, 4)`
    /// members of group `token`, in tab-strip order.
    ///
    /// The returned array is always `min(memberCount, 4)` long. The
    /// chip's `TabGroupChipMosaicView.fillCells` decides what to do
    /// with each entry:
    ///   • `memberCount <= 4`: entry `i` is drawn in slot `i`.
    ///   • `memberCount >= 5`: entries 0..2 are drawn in slots 0..2;
    ///     slot 3 is replaced by the overflow count cell and the 4th
    ///     entry, while collected, is not rendered as a favicon.
    ///
    /// Favicon source per tab:
    ///   1. NTP and internal `phi://` / `chrome://` pages — return
    ///      `phiDefaultFaviconMosaicData` (mirrors `TabItemView`'s
    ///      regular favicon path via `FaviconConfiguration`'s
    ///      classifier, so the mosaic doesn't duplicate the URL
    ///      classification rules).
    ///   2. Otherwise — prefer `liveFaviconData` (current page),
    ///      fall back to `cachedFaviconData` (DB persistence), nil
    ///      when neither exists.
    ///
    /// The lazy chain short-circuits at the 4th match, so a 100-tab
    /// strip with a 5-tab group only walks until 4 group members are
    /// found. `Array(...)` materializes the result so the return
    /// type is a concrete `[Data?]`.
    private func collectMosaicFaviconData(for token: String) -> [Data?] {
        return Array(
            browserState.normalTabs
                .lazy
                .filter { $0.groupToken == token }
                .prefix(4)
                .map { tab -> Data? in
                    if let urlString = tab.url,
                       let url = URL(string: urlString),
                       FaviconConfiguration.shouldUseDefaultFavicon(for: url) {
                        return self.phiDefaultFaviconMosaicData()
                    }
                    return tab.liveFaviconData ?? tab.cachedFaviconData
                }
        )
    }

    /// Re-measures the full-mode chip width for `token`. Called on group
    /// creation and whenever the group's title / color / member count
    /// changes (or when the tab list changes for an auto-named group).
    private func refreshChipWidth(for token: String) {
        guard let group = browserState.groups[token] else {
            chipFullWidths.removeValue(forKey: token)
            return
        }
        let memberCount = browserState.normalTabs
            .lazy.filter { $0.groupToken == token }.count
        let title = group.displayTitle(memberCount: memberCount)
        let width = TabGroupChipView.chipWidth(
            forTitle: title,
            hasUserSetTitle: group.hasUserSetTitle,
            memberCount: memberCount,
            isCollapsed: effectiveIsCollapsed(for: token)
        )
        chipFullWidths[token] = width
    }

    private func updateNormalContainerMask() {
        let visibleWidth = normalContainer.bounds.width
        if lastContentWidth <= visibleWidth {
            normalContainer.layer?.mask = nil
            return
        }

        let maxScroll = max(0, lastContentWidth - visibleWidth)
        let isAtStart = currentScrollOffset <= 1.0
        let isAtEnd = currentScrollOffset >= maxScroll - 1.0

        // Define the clipping margins.
        let leftClip: CGFloat = normalTabContainerOffset + TabStripMetrics.Tab.spacing
        let rightClip: CGFloat = TabStripMetrics.NewTabButton.size.width + TabStripMetrics.Tab.spacing + TabStripMetrics.Tab.spacing

        // Keep the edges visible but hard-clip the middle when content scrolls.
        let startX = isAtStart ? 0 : leftClip
        let endX = isAtEnd ? visibleWidth : (visibleWidth - rightClip)

        containerMaskLayer.frame = normalContainer.bounds
        containerMaskLayer.fillColor = NSColor.black.cgColor
        containerMaskLayer.path = CGPath(rect: CGRect(
            x: startX,
            y: 0,
            width: max(0, endX - startX),
            height: normalContainer.bounds.height
        ), transform: nil)

        normalContainer.layer?.mask = containerMaskLayer
    }

    private func isTabActive(_ tab: Tab, activeTab: Tab?) -> Bool {
        guard let activeTab = activeTab else { return false }
        if tab === activeTab { return true }
        if tab.guid > 0 && tab.guid == activeTab.guid { return true }
        if let dbId = tab.guidInLocalDB, !dbId.isEmpty,
           let activeDbId = activeTab.guidInLocalDB, !activeDbId.isEmpty {
            return dbId == activeDbId
        }
        // The strip only renders the primary of a split. When focus moves to
        // the secondary pane, `activeTab` is the partner — match by split
        // group so the rendered primary cell still earns the active width.
        if tab.guid > 0, activeTab.guid > 0,
           let group = browserState.splitGroup(forTabId: tab.guid),
           group.contains(tabId: activeTab.guid) {
            return true
        }

        return false
    }

    private func handleTabSelection(tab: Tab?) {
        guard let tab = tab else { return }
        browserState.clearGroupOverview()
        if tab.isPinned {
            self.browserState.openOrFocusPinnedTab(tab)
        } else {
            self.scrollToMakeTabVisible(tab)
            tab.makeSelfActive()
        }
    }

    private func handleNewTabButtonClick() {
        unsafeBrowserWindowController?.newBrowserTab(nil)
    }

    private func updateDragScreenPoint(from event: NSEvent) {
        guard let window = event.window else { return }
        let pointInScreen = window.convertPoint(toScreen: event.locationInWindow)
        lastDragScreenPoint = CGPoint(x: pointInScreen.x, y: pointInScreen.y)
    }

    /// Chip-drag variant: chip's drag callbacks deliver window-coord
    /// points (no NSEvent), so we need a window-point → screen-point
    /// converter independent of `updateDragScreenPoint(from:)`. Uses
    /// `self.window` because the chip lives in the source TabStrip.
    private func updateDragScreenPoint(fromWindowPoint windowPoint: CGPoint) {
        guard let window else { return }
        let pointInScreen = window.convertPoint(toScreen: windowPoint)
        lastDragScreenPoint = CGPoint(x: pointInScreen.x, y: pointInScreen.y)
    }

    private func finalizeDragScreenPoint() -> CGPoint? {
        let point = NSEvent.mouseLocation
        lastDragScreenPoint = CGPoint(x: point.x, y: point.y)
        return lastDragScreenPoint
    }

    private func resolveExternalDropTarget(for screenPoint: CGPoint) -> ExternalDropTarget? {
        guard let (targetWindowController, targetStrip) = visibleExternalTabStripTarget(for: screenPoint) else {
            return nil
        }
        // Both preview and commit go through the same resolver on the
        // target strip — that's how visual/commit agreement is
        // guaranteed (spec §5.4). The resolver handles run-boundary
        // snap and JOIN detection intrinsically.
        guard let intent = targetStrip.resolveSingleTabDropIntent(forScreenPoint: screenPoint) else {
            return nil
        }
        return ExternalDropTarget(
            windowController: targetWindowController,
            zone: intent.zone,
            index: intent.index,
            targetGroupToken: intent.joinGroupToken,
            joinAnchorIsBefore: intent.joinAnchorIsBefore
        )
    }

    func updateExternalDragPreview(screenPoint: CGPoint) {
        guard dragController.context == nil else { return }

        // Collapsed-chip hover-expand timer: independent of preview
        // resolution because the resolver currently treats collapsed
        // chips as see-through. See spec §6.
        if let collapsedToken = hoveredCollapsedChipToken(forScreenPoint: screenPoint) {
            armCollapsedChipExpandTimer(token: collapsedToken)
        } else {
            cancelCollapsedChipExpandTimer()
        }

        guard let intent = resolveSingleTabDropIntent(forScreenPoint: screenPoint) else {
            clearExternalDragPreview()
            return
        }
        let gapWidth: CGFloat? = (intent.zone == .normal)
            ? currentAverageNormalTabWidth()
            : nil
        let nextPreview = ExternalDragPreview(
            zone: intent.zone,
            index: intent.index,
            gapWidth: gapWidth,
            joinRunToken: intent.joinGroupToken
        )
        if let existing = externalDragPreview,
           existing.zone == nextPreview.zone,
           existing.index == nextPreview.index,
           existing.gapWidth == nextPreview.gapWidth,
           existing.joinRunToken == nextPreview.joinRunToken {
            return
        }
        externalDragPreview = nextPreview
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Returns the token of the collapsed chip currently under
    /// `screenPoint`, or nil if no collapsed chip is hit. Used by
    /// `updateExternalDragPreview` to manage the 300ms hover-expand
    /// timer (spec §6). Stays separate from `resolveSingleTabDropIntent`
    /// so the resolver remains a pure function of (cursor, strip state).
    private func hoveredCollapsedChipToken(forScreenPoint screenPoint: CGPoint) -> String? {
        guard let window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: NSPoint(x: screenPoint.x, y: screenPoint.y))
        let localPoint = convert(windowPoint, from: nil)
        let metrics = dragControllerRequestMetrics()
        guard metrics.normalContainerFrame.contains(localPoint) else { return nil }
        let normalX = localPoint.x - metrics.normalContainerFrame.minX + metrics.normalScrollOffset
        let collapsedTokens = Set(currentGroupRuns().filter { $0.isCollapsed }.map { $0.token })
        for cf in metrics.chipFrames {
            guard collapsedTokens.contains(cf.token) else { continue }
            if normalX >= cf.frame.minX, normalX < cf.frame.maxX {
                return cf.token
            }
        }
        return nil
    }

    private func armCollapsedChipExpandTimer(token: String) {
        if collapsedChipExpandToken == token, collapsedChipExpandTimer != nil {
            // Same chip, timer already armed — let it run.
            return
        }
        cancelCollapsedChipExpandTimer()
        collapsedChipExpandToken = token
        collapsedChipExpandTimer = Timer.scheduledTimer(
            withTimeInterval: 0.3,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            guard self.collapsedChipExpandToken == token else { return }
            self.collapsedChipExpandToken = nil
            self.collapsedChipExpandTimer = nil
            guard let group = self.browserState.groups[token], group.isCollapsed else { return }
            AppLogDebug(
                "[TabStrip][ExternalDrag] auto-expand collapsed chip " +
                "windowId=\(self.browserState.windowId) token=\(token)"
            )
            ChromiumLauncher.sharedInstance().bridge?.updateTabGroupCollapsed(
                withWindowId: Int64(self.browserState.windowId),
                tokenHex: token,
                isCollapsed: false
            )
        }
    }

    private func cancelCollapsedChipExpandTimer() {
        collapsedChipExpandTimer?.invalidate()
        collapsedChipExpandTimer = nil
        collapsedChipExpandToken = nil
    }

    /// Target-side receiver for whole-group drag previews. Called by
    /// the **source** strip's `updateExternalPreviewTarget` when the
    /// cursor moves over this strip while a chip drag is active in
    /// another window. Reuses `ExternalDragPreview`'s gapWidth field —
    /// caller passes the source slice's measured `initialSliceWidth`,
    /// which already includes chip + members + interior spacing, so
    /// the layout engine renders a gap whose width matches what will
    /// land at commit. Group-aware drop index is computed locally via
    /// `groupDropTarget(forScreenPoint:)` (chip-hit-test + run-interior
    /// snap), so the visual cue and the eventual commit agree.
    ///
    /// Returns silently with no preview if this strip is itself
    /// dragging (single-tab or group), if the cursor is in the pinned
    /// zone, or if it falls outside both containers.
    func updateExternalGroupDragPreview(screenPoint: CGPoint, sliceWidth: CGFloat) {
        guard dragController.context == nil, groupDragController.context == nil else { return }
        guard let target = groupDropTarget(forScreenPoint: screenPoint) else {
            clearExternalDragPreview()
            return
        }
        let nextPreview = ExternalDragPreview(
            zone: target.zone,
            index: target.index,
            gapWidth: sliceWidth,
            joinRunToken: nil
        )
        if let existing = externalDragPreview,
           existing.zone == nextPreview.zone,
           existing.index == nextPreview.index,
           existing.gapWidth == nextPreview.gapWidth,
           existing.joinRunToken == nextPreview.joinRunToken {
            return
        }
        externalDragPreview = nextPreview
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func clearExternalDragPreview() {
        // Always reset cross-window per-chip hysteresis + cancel the
        // collapsed-chip expand timer (both cheap, no layout cost).
        // The resolver self-resets the token when the cursor misses
        // all chips, but this is defensive for the path where the
        // cursor exits the strip entirely.
        externalHoverGapBeforeChipToken = nil
        cancelCollapsedChipExpandTimer()
        guard externalDragPreview != nil else { return }
        externalDragPreview = nil
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func currentAverageNormalTabWidth() -> CGFloat {
        let frames = browserState.normalTabs.compactMap { tab -> CGRect? in
            let frame = normalTabViews[tab.uniqueId]?.frame ?? .zero
            return frame == .zero ? nil : frame
        }
        guard !frames.isEmpty else {
            return TabStripMetrics.Tab.idealWidth
        }
        let totalWidth = frames.reduce(0) { $0 + $1.width }
        return totalWidth / CGFloat(frames.count)
    }

    private func ensureDragImageWindow() -> NSPanel {
        if let dragImageWindow {
            return dragImageWindow
        }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let imageView = NSImageView(frame: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        panel.contentView = imageView

        dragImageWindow = panel
        dragImageView = imageView
        return panel
    }

    private func hideFloatingDragPreview() {
        dragImageWindow?.orderOut(nil)
        dragImageView?.image = nil
    }

    private func dragImageFrame(around screenPoint: CGPoint, size: CGSize) -> CGRect {
        let origin = CGPoint(
            x: screenPoint.x - size.width * 0.5,
            y: screenPoint.y - size.height * 0.25
        )
        return CGRect(origin: origin, size: size)
    }

    private func updateFloatingDragPreview(screenPoint: CGPoint) {
        // Route by active drag controller. Single-tab path stays exactly
        // as before. Whole-group path uses a chip-only snapshot (no
        // page-snapshot variant; per 2026-05-12 plan §Design Decision 1)
        // and never falls back to a tab snapshot.
        if let context = dragController.context {
            updateSingleTabFloatingDragPreview(context: context, screenPoint: screenPoint)
        } else if let groupCtx = groupDragController.context {
            updateGroupFloatingDragPreview(context: groupCtx, screenPoint: screenPoint)
        } else {
            hideFloatingDragPreview()
            setSourceGroupVisualsHidden(false)
        }
    }

    private func updateSingleTabFloatingDragPreview(context: TabDragContext, screenPoint: CGPoint) {
        let shouldUsePageSnapshot = browserState.tabDraggingSession.shouldUsePageSnapshotPreview(at: screenPoint)
        if !shouldUsePageSnapshot, isInsideDragBoundary(screenPoint) {
            draggingProxyView?.alphaValue = 1
            draggingSiblingProxyView?.alphaValue = 1
            hideFloatingDragPreview()
            return
        }

        let image: NSImage?
        if shouldUsePageSnapshot {
            if cachedPageDragImage == nil {
                cachedPageDragImage = browserState.tabDraggingSession.pageSnapshotImage(for: context.draggingTab)
            }
            image = cachedPageDragImage ?? cachedTabDragImage
        } else {
            if cachedTabDragImage == nil {
                cachedTabDragImage = draggingProxyView?.createDraggingSnapshot(
                    cornerRadius: TabStripMetrics.Tab.cornerRadius
                ) ?? draggingSourceView?.createDraggingSnapshot(
                    cornerRadius: TabStripMetrics.Tab.cornerRadius
                )
            }
            image = cachedTabDragImage ?? cachedPageDragImage
        }
        guard let image else { return }
        draggingProxyView?.alphaValue = 0
        // Keep the sibling proxy in sync so the pair always reads as one
        // unit, whether shown in the strip or in the floating preview panel.
        draggingSiblingProxyView?.alphaValue = 0

        let panel = ensureDragImageWindow()
        dragImageView?.image = image
        dragImageView?.frame = CGRect(origin: .zero, size: image.size)

        let frame = dragImageFrame(around: screenPoint, size: image.size)
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    /// Floating chip preview for whole-group drag. Visibility gate:
    /// while the cursor stays inside the source strip boundary, the
    /// in-strip transform (applied to chip + members) follows the
    /// cursor — no floating preview needed, and source visuals stay
    /// at alpha=1. Once the cursor leaves (into another window or to
    /// the desktop), the in-strip chip + members visually freeze and
    /// would otherwise look out of place, so we set their alpha to 0
    /// and show a floating chip-only snapshot at the cursor.
    private func updateGroupFloatingDragPreview(context: TabGroupDragContext, screenPoint: CGPoint) {
        let insideSource = isInsideDragBoundary(screenPoint)
        if insideSource {
            hideFloatingDragPreview()
            setSourceGroupVisualsHidden(false)
            return
        }

        if context.cachedChipDragImage == nil {
            context.cachedChipDragImage = chipViews[context.draggingChipToken]?
                .createDraggingSnapshot(cornerRadius: TabStripMetrics.Tab.cornerRadius)
        }
        guard let image = context.cachedChipDragImage else { return }

        setSourceGroupVisualsHidden(true)

        let panel = ensureDragImageWindow()
        dragImageView?.image = image
        dragImageView?.frame = CGRect(origin: .zero, size: image.size)

        let frame = dragImageFrame(around: screenPoint, size: image.size)
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    /// Toggle source-strip chip + members alpha for the floating-preview
    /// hand-off. Called by `updateGroupFloatingDragPreview` when the
    /// cursor crosses the source boundary either direction. Idempotent
    /// per-view (setting alphaValue to the same value is a no-op).
    private func setSourceGroupVisualsHidden(_ hidden: Bool) {
        guard let ctx = groupDragController.context else { return }
        let alpha: CGFloat = hidden ? 0 : 1
        chipViews[ctx.draggingChipToken]?.alphaValue = alpha
        let memberIdSet = Set(ctx.memberTabIds)
        for tab in browserState.normalTabs where memberIdSet.contains(tab.guid) {
            normalTabViews[tab.uniqueId]?.alphaValue = alpha
        }
    }

    /// Drag-end variant of `setSourceGroupVisualsHidden(false)` that
    /// takes the token + memberIds explicitly because the controller
    /// has already cleared its context by the time we tear down on
    /// `onDragEnd`. The same-window commit path triggers a fresh
    /// layout that creates new views with default alpha = 1, so this
    /// is only load-bearing for the `.external` / `.tearOff` paths
    /// (where the existing source views are reused and would otherwise
    /// stay invisible). Calling it always is safe and idempotent.
    private func restoreSourceGroupVisuals(token: String, memberIds: [Int]) {
        chipViews[token]?.alphaValue = 1
        let memberIdSet = Set(memberIds)
        for tab in browserState.normalTabs where memberIdSet.contains(tab.guid) {
            normalTabViews[tab.uniqueId]?.alphaValue = 1
        }
    }

    private func updateExternalPreviewTarget(screenPoint: CGPoint) {
        // Active drag must be either single-tab or whole-group.
        let groupCtx = groupDragController.context
        guard dragController.context != nil || groupCtx != nil else { return }

        let targetStrip = visibleExternalTabStripTarget(for: screenPoint)?.tabStrip

        if externalPreviewTargetStrip !== targetStrip {
            externalPreviewTargetStrip?.clearExternalDragPreview()
            externalPreviewTargetStrip = targetStrip
        }

        guard let targetStrip else {
            return
        }
        if let groupCtx {
            // Whole-group preview: target renders an "empty slot" the
            // exact width of the source slice. Group-aware index snap
            // happens on the target side via groupDropTarget(...).
            targetStrip.updateExternalGroupDragPreview(
                screenPoint: screenPoint,
                sliceWidth: groupCtx.initialSliceWidth
            )
        } else {
            targetStrip.updateExternalDragPreview(screenPoint: screenPoint)
        }
    }

    private func visibleExternalTabStripTarget(for screenPoint: CGPoint) -> (windowController: MainBrowserWindowController, tabStrip: TabStrip)? {
        let point = NSPoint(x: screenPoint.x, y: screenPoint.y)
        let sourceWindowController = unsafeBrowserWindowController
        let windowManager = MainBrowserWindowControllersManager.shared

        for window in NSApp.orderedWindows where window.frame.contains(point) {
            guard let windowController = windowManager.findControllerWith(window: window) else {
                continue
            }
            if windowController === sourceWindowController {
                return nil
            }
            guard windowController.browserState.canAcceptCrossWindowDrag(from: browserState),
                  let tabStrip = windowController.tabStripView,
                  tabStrip.isInsideDragBoundary(screenPoint) else {
                return nil
            }
            return (windowController, tabStrip)
        }

        if sourceWindowController?.window?.frame.contains(point) == true {
            return nil
        }

        return windowManager.getAllWindows().compactMap { windowController in
            guard windowController !== sourceWindowController,
                  windowController.window?.frame.contains(point) == true,
                  windowController.browserState.canAcceptCrossWindowDrag(from: browserState),
                  let tabStrip = windowController.tabStripView,
                  tabStrip.isInsideDragBoundary(screenPoint) else {
                return nil
            }
            return (windowController, tabStrip)
        }.first
    }

    private func clearExternalPreviewTarget() {
        externalPreviewTargetStrip?.clearExternalDragPreview()
        externalPreviewTargetStrip = nil
    }

    /// Returns the same-window SplitTabDropContainer (and its current split
    /// zone) for the given screen point, if any. Returns `nil` when the point
    /// isn't inside this window's content area's left/right third, or when
    /// the focused tab isn't a valid split partner for the dragged tab.
    private func resolveSplitDropTarget(for screenPoint: CGPoint, draggedTabId: Int)
        -> (container: SplitTabDropContainer, zone: SplitTabDropContainer.DropZone)? {
        guard let windowController = unsafeBrowserWindowController,
              windowController.window?.frame.contains(NSPoint(x: screenPoint.x, y: screenPoint.y)) == true,
              let container = windowController.mainSplitViewController.webContentContainerViewController.splitTabDropContainer as SplitTabDropContainer?,
              let zone = container.splitZoneForScreenPoint(screenPoint, draggedTabId: draggedTabId) else {
            return nil
        }
        return (container, zone)
    }

    private func updateSplitHint(for screenPoint: CGPoint?, draggedTabId: Int?) {
        guard let screenPoint, let draggedTabId,
              let windowController = unsafeBrowserWindowController,
              windowController.window?.frame.contains(NSPoint(x: screenPoint.x, y: screenPoint.y)) == true else {
            clearSplitHint()
            return
        }
        let container = windowController.mainSplitViewController.webContentContainerViewController.splitTabDropContainer
        guard container.isSplitDragContextValid(at: screenPoint, draggedTabId: draggedTabId) else {
            clearSplitHint()
            return
        }
        if splitHintTargetContainer !== container {
            splitHintTargetContainer?.hideSplitDropHints()
        }
        container.showSplitDropHints(draggedTabId: draggedTabId)
        splitHintTargetContainer = container
    }

    private func clearSplitHint() {
        splitHintTargetContainer?.hideSplitDropHints()
        splitHintTargetContainer = nil
    }

    private func isInsideDragBoundary(_ screenPoint: CGPoint) -> Bool {
        guard let window else { return false }
        let pointInWindow = window.convertPoint(fromScreen: NSPoint(x: screenPoint.x, y: screenPoint.y))
        let pointInContainer = convert(pointInWindow, from: nil)
        return bounds.contains(pointInContainer)
    }

    private func resolveDropAction(for screenPoint: CGPoint) -> PendingDropAction {
        if let target = resolveExternalDropTarget(for: screenPoint) {
            return .external(target)
        }
        if isInsideDragBoundary(screenPoint) {
            return .local
        }
        if let draggedTabId = dragController.context?.draggingTab.guid,
           let splitTarget = resolveSplitDropTarget(for: screenPoint, draggedTabId: draggedTabId) {
            return .splitWithFocused(splitTarget.zone)
        }
        return .tearOff
    }

    private func moveTabToWindow(
        _ tab: Tab,
        targetState: BrowserState,
        scheduleNormalInsertion: Bool,
        index: Int
    ) -> Bool {
        guard let wrapper = tab.webContentWrapper else { return false }
        // Split-aware: when the dragged tab belongs to a split, the Chromium
        // bridge re-creates the pair atomically at the requested index. Skip
        // the local schedule + tail-insert dance — its post-arrival per-tab
        // moveTab callback would yank the dragged half out of the new split
        // and break the pair.
        if browserState.splitGroup(forTabId: tab.guid) != nil {
            let clampedIndex = max(0, min(index, targetState.tabs.count))
            wrapper.moveSplit(toWindow: targetState.windowId.int64Value, at: clampedIndex)
            return true
        }
        if scheduleNormalInsertion {
            targetState.scheduleNormalTabInsertion(tabGuid: tab.guid, at: index)
        }
        let insertIndex = max(0, targetState.tabs.count)
        wrapper.moveSplit(toWindow: targetState.windowId.int64Value, at: insertIndex)
        return true
    }

    /// Cross-window single-tab move that ALSO joins a target group on
    /// arrival. Resolves the anchor `Tab` from `targetState.normalTabs`
    /// at `atIndex` (± `anchorIsBefore`), reads its `guid.int64Value`
    /// for the bridge's `anchorTabId:` parameter (Mac-side `Tab.guid`
    /// IS the Chromium int64 tab id — see `BrowserState.swift:1727`
    /// for the established conversion pattern), pre-schedules the slot,
    /// then fires the wrapper's group-aware cross-window move. See
    /// spec §5.4.
    ///
    /// Falls back to ordinary cross-window move (ungrouped on arrival)
    /// when the anchor index is out of bounds — defensive guard so a
    /// resolver edge case can never produce a no-op.
    private func moveTabToWindowJoiningGroup(
        _ tab: Tab,
        targetState: BrowserState,
        atIndex: Int,
        joinToken: String,
        anchorIsBefore: Bool
    ) -> Bool {
        guard let wrapper = tab.webContentWrapper else { return false }
        let clampedIndex = min(max(0, atIndex), targetState.normalTabs.count)

        // anchorIsBefore == true  → anchor = tab AT clampedIndex (insert before it)
        // anchorIsBefore == false → anchor = tab BEFORE clampedIndex (insert after it)
        let anchorIdx = anchorIsBefore ? clampedIndex : clampedIndex - 1
        guard anchorIdx >= 0, anchorIdx < targetState.normalTabs.count else {
            return moveTabToWindow(
                tab,
                targetState: targetState,
                scheduleNormalInsertion: true,
                index: clampedIndex
            )
        }
        let anchorTabId = Int64(targetState.normalTabs[anchorIdx].guid)

        targetState.scheduleNormalTabInsertion(tabGuid: tab.guid, at: clampedIndex)

        // Park the tab's favicon in the shared cross-window stash so
        // the destination's `handleNewTabFromChromium` seeds the
        // fresh Tab's `cachedFaviconData` before any chip-mosaic
        // read. The collapsed-chip hover-expand timer means the join
        // commit lands while the target group is expanded (no mosaic
        // rendered at that instant), but the user can later collapse
        // the group manually — that's when the mosaic first reads
        // this member's favicon. Without the stash, the destination
        // wrapper has nil `favIconData` and the slot stays blank.
        // See `BrowserState.crossWindowFaviconStash` for the why.
        BrowserState.stashCrossWindowFavicons(forMemberIds: [tab.guid], in: [tab])

        let targetWindowId = targetState.windowId.int64Value
        if anchorIsBefore {
            wrapper.moveSelf(
                toWindow: targetWindowId,
                andAddToGroupTokenHex: joinToken,
                beforeTabId: anchorTabId
            )
        } else {
            wrapper.moveSelf(
                toWindow: targetWindowId,
                andAddToGroupTokenHex: joinToken,
                afterTabId: anchorTabId
            )
        }
        return true
    }

    private func dropTarget(forScreenPoint screenPoint: CGPoint) -> (zone: TabContainerType, index: Int) {
        guard let window else {
            return (.normal, browserState.normalTabs.count)
        }
        let windowPoint = window.convertPoint(fromScreen: NSPoint(x: screenPoint.x, y: screenPoint.y))
        let localPoint = convert(windowPoint, from: nil)
        let metrics = dragControllerRequestMetrics()

        if metrics.pinnedContainerFrame.contains(localPoint) {
            let localX = localPoint.x - metrics.pinnedContainerFrame.minX
            let index = calculateGapIndex(localX: localX, tabFrames: metrics.pinnedTabFrames, excludedIndex: nil)
            return (.pinned, index)
        }
        if metrics.normalContainerFrame.contains(localPoint) {
            let localX = localPoint.x - metrics.normalContainerFrame.minX + metrics.normalScrollOffset
            let index = calculateGapIndex(localX: localX, tabFrames: metrics.normalTabFrames, excludedIndex: nil)
            return (.normal, index)
        }

        return (.normal, browserState.normalTabs.count)
    }

    private func calculateGapIndex(
        localX: CGFloat,
        tabFrames: [CGRect],
        excludedIndex: Int?
    ) -> Int {
        var visibleFrames: [(index: Int, frame: CGRect)] = []
        for (i, frame) in tabFrames.enumerated() {
            if let exclude = excludedIndex, i == exclude {
                continue
            }
            if frame == .zero {
                continue
            }
            visibleFrames.append((i, frame))
        }

        if visibleFrames.isEmpty {
            return 0
        }

        for (arrayIndex, item) in visibleFrames.enumerated() {
            let midX = item.frame.midX
            if localX < midX {
                return calculateActualInsertIndex(
                    visualIndex: arrayIndex,
                    visibleFrames: visibleFrames,
                    excludedIndex: excludedIndex
                )
            }
        }

        if let lastItem = visibleFrames.last {
            return lastItem.index + 1
        }

        return 0
    }

    private func calculateActualInsertIndex(
        visualIndex: Int,
        visibleFrames: [(index: Int, frame: CGRect)],
        excludedIndex: Int?
    ) -> Int {
        if visualIndex < visibleFrames.count {
            return visibleFrames[visualIndex].index
        }
        return visibleFrames.last?.index ?? 0
    }

    private func handleTabDragStart(event: NSEvent, tab: Tab, isPinned: Bool, index: Int, frame: CGRect) {
        let mouseLoc = event.locationInWindow
        updateDragScreenPoint(from: event)
        pendingDropAction = nil
        browserState.tabDraggingSession.begin(
            draggingItem: tab,
            screenLocation: lastDragScreenPoint,
            containerView: self
        )
        let id = tab.uniqueId
        // Resolve the dragged tab's split partner — when present, both members
        // lift, follow the cursor, and drop together. Pinned tabs cannot
        // currently belong to splits, so this only fires in the normal zone.
        let siblingInfo = !isPinned ? resolveDragSibling(for: tab) : nil
        // Merged-split source cell: the strip renders the pair as one wide
        // cell via `pinnedSplitPartners`; the drag proxy must match that
        // layout (two favicons + titles + divider) instead of the
        // merged-bar style that `splitInfo.position` would produce, and
        // the sibling proxy must be suppressed since the partner's source
        // view is already collapsed under the merged cell.
        let normalCollapse = !isPinned ? normalSplitCollapseInfo() : nil
        let pinnedCollapse = isPinned ? pinnedSplitCollapseInfo() : nil
        let mergedSplitPartner: Tab? = {
            if let collapse = normalCollapse { return collapse.partners[id] }
            if let collapse = pinnedCollapse { return collapse.partners[id] }
            return nil
        }()
        draggingMergedPartner = mergedSplitPartner
        let suppressSiblingProxy = mergedSplitPartner != nil
        if let view = isPinned ? pinnedTabViews[id] : normalTabViews[id] {
            // Proxy view carries drag visuals so the source view can stay out of layout flow.
            let splitInfo = splitRenderInfo(for: tab)
            let renderData = TabRenderData(
                id: id,
                title: tab.title,
                url: tab.url ?? "",
                isActive: isTabActive(tab, activeTab: browserState.focusingTab),
                isPinned: isPinned,
                splitPairPosition: mergedSplitPartner == nil ? splitInfo.position : nil,
                isSplitGroupActive: mergedSplitPartner == nil ? splitInfo.groupActive : false,
                pinnedSplitPartner: mergedSplitPartner,
                sourceTab: tab
            )

            let proxy = TabItemView()
            proxy.configure(with: renderData)
            if !renderData.isActive {
                proxy.setDragHighlighted(true)
            }

            // Use the overlay so cross-zone dragging is not clipped by either container.
            let frameInOverlay = dragOverlay.convert(view.frame, from: view.superview)
            proxy.frame = frameInOverlay
            dragOverlay.addSubview(proxy)
            dragOverlay.isHidden = false

            draggingProxyView = proxy
            draggingSourceView = view
            draggingPresentationZone = isPinned ? .pinned : .normal
            proxy.layoutSubtreeIfNeeded()
            cachedTabDragImage = proxy.createDraggingSnapshot(
                cornerRadius: TabStripMetrics.Tab.cornerRadius
            ) ?? view.createDraggingSnapshot(cornerRadius: TabStripMetrics.Tab.cornerRadius)
            cachedPageDragImage = nil
            hideFloatingDragPreview()

            // Hide the source view while the proxy owns drag presentation.
            view.alphaValue = 0
            TabStripAnimationHelper.animateLift(proxy)

            // Build a sibling proxy so the partner lifts alongside the
            // dragged tab; otherwise the user sees a single tab animate even
            // though the data layer moves the whole split. Skipped for the
            // collapsed merged-split case — the partner is already
            // represented inside the single wide proxy above.
            if let siblingInfo, !suppressSiblingProxy {
                let siblingFrameInOverlay = dragOverlay.convert(
                    siblingInfo.sourceView.frame,
                    from: siblingInfo.sourceView.superview
                )
                let siblingRenderData = TabRenderData(
                    id: siblingInfo.tab.uniqueId,
                    title: siblingInfo.tab.title,
                    url: siblingInfo.tab.url ?? "",
                    isActive: isTabActive(siblingInfo.tab, activeTab: browserState.focusingTab),
                    isPinned: false,
                    splitPairPosition: browserState.splitPairPosition(forTabId: siblingInfo.tab.guid),
                    isSplitGroupActive: splitInfo.groupActive,
                    sourceTab: siblingInfo.tab
                )
                let siblingProxy = TabItemView()
                siblingProxy.configure(with: siblingRenderData)
                if !siblingRenderData.isActive {
                    siblingProxy.setDragHighlighted(true)
                }
                siblingProxy.frame = siblingFrameInOverlay
                dragOverlay.addSubview(siblingProxy)
                draggingSiblingProxyView = siblingProxy
                draggingSiblingSourceView = siblingInfo.sourceView
                draggingSiblingPlacement = (
                    index: siblingInfo.index,
                    offsetX: siblingFrameInOverlay.minX - frameInOverlay.minX
                )
                siblingProxy.layoutSubtreeIfNeeded()
                siblingInfo.sourceView.alphaValue = 0
                TabStripAnimationHelper.animateLift(siblingProxy)
            }
        }
        self.dragController.startDragging(
            tab: tab,
            sourceIndex: index,
            sourceZone: isPinned ? .pinned : .normal,
            mouseLocation: mouseLoc,
            // Keep the initial frame in overlay coordinates for drag math.
            tabFrame: dragOverlay.convert(frame, from: isPinned ? pinnedContainer : normalContainer),
            siblingSourceIndex: siblingInfo?.index
        )
        if browserState.multiSelection.isActive {
            browserState.clearMultiSelection()
        }
    }

    /// Returns the source view, tab, and tab-strip index of the dragged tab's
    /// split partner in the normal zone, or nil when the tab isn't paired.
    private func resolveDragSibling(for tab: Tab) -> (tab: Tab, sourceView: TabItemView, index: Int)? {
        guard let group = browserState.splitGroup(forTabId: tab.guid) else {
            return nil
        }
        guard let partnerId = group.partnerTabId(of: tab.guid),
              let partnerIndex = browserState.normalTabs.firstIndex(where: { $0.guid == partnerId }) else {
            return nil
        }
        let partner = browserState.normalTabs[partnerIndex]
        guard let partnerView = normalTabViews[partner.uniqueId] else {
            return nil
        }
        return (partner, partnerView, partnerIndex)
    }

    /// Indices excluded from the source zone's layout: the dragged tab and
    /// (for split-pair drags) its partner.
    private func sourceExclusionSet(for context: TabDragContext?) -> Set<Int> {
        guard let context else { return [] }
        var set: Set<Int> = [context.sourceIndex]
        if let sibling = context.siblingSourceIndex {
            set.insert(sibling)
        }
        return set
    }

    private func handleTabDragUpdate(event: NSEvent) {
        let mouseLoc = event.locationInWindow
        updateDragScreenPoint(from: event)
        browserState.tabDraggingSession.update(
            screenLocation: lastDragScreenPoint,
            containerView: self
        )
        dragController.updateDragging(mouseLocation: mouseLoc)
        updateDraggingViewPosition()
        if let screenPoint = lastDragScreenPoint {
            updateFloatingDragPreview(screenPoint: screenPoint)
            updateExternalPreviewTarget(screenPoint: screenPoint)
            // External drop and "still over our own strip" both take priority
            // over the split hint, so suppress it in those cases.
            let isOverOwnStrip = isInsideDragBoundary(screenPoint)
            let hasExternalTarget = externalPreviewTargetStrip != nil
            if isOverOwnStrip || hasExternalTarget {
                clearSplitHint()
            } else {
                updateSplitHint(for: screenPoint,
                                draggedTabId: dragController.context?.draggingTab.guid)
            }
        }
    }

    private func handleTabDragEnd() {
        pendingDropAction = nil
        if let screenPoint = finalizeDragScreenPoint() {
            browserState.tabDraggingSession.update(
                screenLocation: screenPoint,
                containerView: self
            )
            pendingDropAction = resolveDropAction(for: screenPoint)
        }
        clearExternalPreviewTarget()
        clearSplitHint()
        let shouldForceEnd: Bool
        switch pendingDropAction {
        case .external, .tearOff, .splitWithFocused:
            shouldForceEnd = true
        case .local, .none:
            shouldForceEnd = false
        }
        dragController.endDragging(force: shouldForceEnd)
    }
}

extension Tab {
    var uniqueId: String {
        if let dbId = guidInLocalDB, !dbId.isEmpty { return dbId }
        if guid > 0 { return String(guid) }
        return String(ObjectIdentifier(self).hashValue)
    }
}

// MARK: - TabStripDragDelegate
extension TabStrip: TabStripDragDelegate {
    func dragControllerRequestMetrics() -> TabStripMetricsSnapshot {
        // Collect pinned frames in browser-state order.
        let pinnedFrames = browserState.pinnedTabs.compactMap { tab -> CGRect? in
            return pinnedTabViews[tab.uniqueId]?.frame
        }
        // Collect normal-tab frames in browser-state order.
        let normalFrames = browserState.normalTabs.compactMap { tab -> CGRect? in
            guard let view = normalTabViews[tab.uniqueId] else { return nil }
            return view.frame.offsetBy(dx: currentScrollOffset, dy: 0)
        }

        // Collect chip frames keyed by their group's first-member
        // index in normalTabs. Drag controller uses these to decide
        // which side of the chip the gap should open on at the
        // leading edge.
        let runs = currentGroupRuns()
        let chipFrames: [TabStripChipFrame] = runs.compactMap { run in
            guard let chip = chipViews[run.token], chip.superview != nil else { return nil }
            return TabStripChipFrame(
                token: run.token,
                firstMemberIndex: run.range.lowerBound,
                lastMemberIndex: run.range.upperBound,
                isCollapsed: run.isCollapsed,
                frame: chip.frame.offsetBy(dx: currentScrollOffset, dy: 0)
            )
        }

        // Compute the proxy's current frame in normalContainer
        // coords (same space as `normalTabFrames`), if a drag is
        // active and the proxy is over the normal zone. Used by
        // the drag controller's group-trailing hit testing so
        // thresholds key off the visible tab edges (independent of
        // where the user grabbed inside the tab).
        let draggedTabFrameInNormal: CGRect? = {
            guard let proxy = draggingProxyView,
                  proxy.superview != nil,
                  let ctx = dragController.context,
                  ctx.targetContainerType == .normal else { return nil }
            let proxyInStrip = proxy.convert(proxy.bounds, to: self)
            // Translate from tab-strip space → normalContainer
            // space (matches normalTabFrames offset bookkeeping).
            return proxyInStrip
                .offsetBy(dx: -normalContainer.frame.minX + currentScrollOffset, dy: 0)
        }()

        return TabStripMetricsSnapshot(
            pinnedContainerFrame: pinnedContainer.frame,
            normalContainerFrame: normalContainer.frame,
            pinnedTabWidth: TabStripMetrics.PinnedTab.width,
            normalTabFrames: normalFrames,
            pinnedTabFrames: pinnedFrames,
            normalScrollOffset: currentScrollOffset,
            chipFrames: chipFrames,
            draggedTabFrameInNormal: draggedTabFrameInNormal,
            normalSplitPairLowerIndices: browserState.splitPairLowerIndicesInNormalTabs()
        )
    }

    func dragControllerDidUpdateLayout(
        pinnedExcludedIndices: Set<Int>,
        pinnedGapIndex: Int?,
        normalExcludedIndices: Set<Int>,
        normalGapIndex: Int?,
        normalGapWidth: CGFloat?
    ) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .default)
            ctx.allowsImplicitAnimation = true
            let dragPinnedSplitCollapse = pinnedSplitCollapseInfo()
            let dragNormalSplitCollapse = normalSplitCollapseInfo()
            updateLayoutOnly(
                container: pinnedContainer,
                viewPool: pinnedTabViews,
                tabs: browserState.pinnedTabs,
                activeTab: browserState.focusingTab,
                isPinned: true,
                excludedIndices: pinnedExcludedIndices,
                gapIndex: pinnedGapIndex,
                pinnedSplitCollapsedIndices: dragPinnedSplitCollapse.collapsedIndices,
                pinnedSplitWideIndices: dragPinnedSplitCollapse.wideIndices
            )

            updateLayoutOnly(
                container: normalContainer,
                viewPool: normalTabViews,
                tabs: browserState.normalTabs,
                activeTab: browserState.focusingTab,
                isPinned: false,
                excludedIndices: normalExcludedIndices,
                gapIndex: normalGapIndex,
                gapWidth: normalGapWidth,
                pinnedSplitCollapsedIndices: dragNormalSplitCollapse.collapsedIndices,
                pinnedSplitWideIndices: dragNormalSplitCollapse.wideIndices
            )
        }

        updateDraggingViewPosition()
        // Drag relayout reflows the non-dragged tabs (including the active tab
        // when a sibling is dragged past it); recompute the content border so
        // its gap follows.
        onLayoutChanged?()
    }

    func dragControllerDidEndDrag(tab: Tab, toZone: TabContainerType, toIndex: Int) {
        guard let context = dragController.context else {
            clearDraggingPresentation(using: nil)
            performLayout(context: .dataChanged)
            pendingDropAction = nil
            return
        }
        clearExternalPreviewTarget()
        let screenPoint = lastDragScreenPoint
        let dropAction = pendingDropAction ?? .local
        pendingDropAction = nil

        if case let .external(externalDrop) = dropAction {
            clearDraggingPresentation(using: context)
            _ = handleExternalDrop(tab: tab, context: context, target: externalDrop)
            browserState.tabDraggingSession.end(screenLocation: screenPoint, dragOperation: .move)
            performLayout(context: .dataChanged)
            return
        }

        if case .tearOff = dropAction {
            clearDraggingPresentation(using: context)
            browserState.tabDraggingSession.end(screenLocation: screenPoint)
            performLayout(context: .dataChanged)
            return
        }

        if case let .splitWithFocused(zone) = dropAction {
            clearDraggingPresentation(using: context)
            performSplitWithFocused(draggedTab: tab,
                                    fromPinnedZone: context.sourceContainerType == .pinned,
                                    zone: zone)
            // Treat the drop as consumed locally — the dragged tab stayed in
            // this window, so don't run the tear-off path.
            browserState.tabDraggingSession.end(screenLocation: screenPoint, dragOperation: .move)
            performLayout(context: .dataChanged)
            return
        }

        clearDraggingPresentation(using: context)

        let isOriginalPinned = context.sourceContainerType == .pinned
        let originalIndex = context.sourceIndex

        // Perform the underlying data move first.
        if isOriginalPinned {
            if toZone == .normal {
                // Case: pinned -> normal. A pinned tab dropped onto a group
                // unpins and joins it — pinned splits too: `movePinnedTabOut`
                // folds the pair into the group as a split, same as the
                // sidebar drop path. Every other case keeps the plain
                // move-out behavior.
                if let guid = tab.guidInLocalDB {
                    let joinToken = resolvePinnedDropGroupToken(context: context, toIndex: toIndex)
                    if let token = joinToken,
                       let run = currentGroupRuns().first(where: { $0.token == token }) {
                        let groupIndex = max(0, min(toIndex - run.range.lowerBound, run.range.count))
                        AppLogDebug(
                            "[TAB_GROUPS][STRIP_DRAG] pinned auto-join windowId=\(browserState.windowId) " +
                            "pinnedGuid=\(guid) token=\(token) toIndex=\(toIndex) groupIndex=\(groupIndex)"
                        )
                        browserState.movePinnedTabOut(pinnedGuid: guid, toGroup: token,
                                                      groupIndex: groupIndex, normalTabsIndex: toIndex,
                                                      focusAfterCreate: tab.isActive)
                    } else {
                        browserState.movePinnedTabOut(pinnedGuid: guid, to: toIndex, selectAfterMove: tab.isActive)
                    }
                }
            } else {
                // Case: pinned -> pinned.
                browserState.movePinnedTab(tab: tab, to: toIndex, selectAfterMove: tab.isActive)
            }
        } else {
            if toZone == .pinned {
                // Split-aware: pin the whole pair as a single pinned-split unit
                // when the dragged tab belongs to a live split, matching the
                // sidebar pinned-drop path and the right-click "Pin Split" menu.
                if let splitGroup = browserState.splitGroup(forTabId: tab.guid),
                   !splitGroup.isPinned {
                    browserState.pinSplitInsertingAtPinnedIndex(splitGroup.id, atIndex: toIndex)
                } else {
                    browserState.moveNormalTab(tabId: tab.guid, toPinnd: toIndex, selectAfterMove: tab.isActive)
                }
            } else {
                // Capture the source run BEFORE the local move so the
                // range / index comparison is in the same coordinate
                // system as the engine's drag preview.
                let sourceToken = tab.groupToken
                let preMoveRun = sourceToken.flatMap { token in
                    currentGroupRuns().first(where: { $0.token == token })
                }

                // A bookmark-opened tab keeps its bookmark guid as
                // `guidInLocalDB`, which marks it Phi-managed and barred from
                // tab groups. When this drop will hand the tab to the
                // `moveBookmarkIntoGroup` auto-join below (cursor-gated
                // leading/trailing edge, or a sandwich strictly between two
                // members of one group at the drop position), that method
                // graduates the tab and re-seats it in Chromium itself — so
                // the local move here must NOT also sync the still-blocked tab
                // to an in-group index. That `bridge.moveTab` would land a
                // group-less tab inside a group's collection range and crash
                // Chromium's tab-collection move. Skip the Chromium sync for
                // that case (the local reorder still runs, so the auto-join's
                // index math is unaffected); keep it for every other drop.
                let bookmarkJoinsGroup: Bool = {
                    guard let dbGuid = tab.guidInLocalDB,
                          browserState.splitGroup(forTabId: tab.guid) == nil,
                          let bookmark = browserState.bookmarkManager.bookmark(withGuid: dbGuid),
                          !bookmark.isFolder else {
                        return false
                    }
                    if context.targetGroupForLeadingJoin != nil { return true }
                    if context.targetGroupForTrailingJoin != nil { return true }
                    let order = browserState.normalTabs
                    guard toIndex - 1 >= 0, toIndex < order.count else { return false }
                    let leftToken = order[toIndex - 1].groupToken
                    let rightToken = order[toIndex].groupToken
                    return leftToken != nil && leftToken == rightToken
                }()

                browserState.moveNormalTabLocally(from: originalIndex, to: toIndex,
                                                  syncChromiumOrder: !bookmarkJoinsGroup)

                // Auto-leave: detach when the drop signals "out of
                // group" intent. THREE disjoint triggers, mirroring
                // the auto-join structure:
                //
                // 1. Geometric — the drop's toIndex falls outside the
                //    group's pre-move range. Reliable when the cursor
                //    moves past a tab adjacent to the group.
                //
                // 2. Cursor-gated leading edge — the drag controller
                //    set `targetGroupForLeadingLeave` to the dragged
                //    tab's own group's token because the cursor sat
                //    strictly before that group's chip. Required for
                //    the first group in the strip, where `lowerBound`
                //    is 0 and the geometric check can never trigger.
                //
                // 3. Cursor-gated trailing edge — the drag controller
                //    set `targetGroupForTrailingLeave` because the
                //    cursor crossed the right edge of the group's
                //    last visible member. Required for the slot
                //    immediately after the group's last member, where
                //    the geometric check (`toIndex > upperBound + 1`)
                //    cannot trigger until the cursor also clears the
                //    next tab's midX (or when no next tab exists at
                //    the strip's tail).
                if let sourceToken {
                    let outsideRange: Bool = {
                        guard let run = preMoveRun else { return false }
                        return toIndex < run.range.lowerBound
                            || toIndex > run.range.upperBound + 1
                    }()
                    let cursorRequestsLeadingLeave = (context.targetGroupForLeadingLeave == sourceToken)
                    let cursorRequestsTrailingLeave = (context.targetGroupForTrailingLeave == sourceToken)
                    if outsideRange || cursorRequestsLeadingLeave || cursorRequestsTrailingLeave {
                        let trigger: String = {
                            if outsideRange { return "outsideRange" }
                            if cursorRequestsLeadingLeave { return "cursorBeforeChip" }
                            return "cursorPastTrailingEdge"
                        }()
                        // Splits leave a group as a unit so the merged-row
                        // invariant survives the boundary crossing.
                        let leavePartner: Tab? = {
                            guard let group = browserState.splitGroup(forTabId: tab.guid),
                                  !group.isPinned,
                                  let partnerId = group.partnerTabId(of: tab.guid),
                                  let partner = browserState.tabs.first(where: { $0.guid == partnerId }),
                                  partner.groupToken == sourceToken else {
                                return nil
                            }
                            return partner
                        }()
                        var memberIds: [NSNumber] = [NSNumber(value: Int64(tab.guid))]
                        if let partner = leavePartner {
                            memberIds.append(NSNumber(value: Int64(partner.guid)))
                        }
                        AppLogDebug(
                            "[TAB_GROUPS][STRIP_DRAG] auto-leave windowId=\(browserState.windowId) " +
                            "tabIds=\(memberIds) token=\(sourceToken) trigger=\(trigger)"
                        )
                        ChromiumLauncher.sharedInstance().bridge?.removeTabsFromGroup(
                            withWindowId: Int64(browserState.windowId),
                            tabIds: memberIds
                        )
                        // Optimistic local update — symmetric with the
                        // auto-join site below. The bridge returns
                        // synchronously but `tabLeftGroup` rides the
                        // EventBus -> Task { @MainActor } async hop,
                        // so without clearing the token here, T would
                        // sit at its new position outside the source
                        // group's range while still carrying
                        // groupToken=sourceToken. `currentGroupRuns()`
                        // in the upcoming performLayout would then see
                        // GA's other members at their contiguous range
                        // + T alone elsewhere = 2 runs of sourceToken
                        // and trip the contiguity assertion. Route
                        // through the batched
                        // `applyOptimisticGroupMembership(updates:)`
                        // so both panes of a split clear their token
                        // atomically (single publish), avoiding the
                        // transient `[member, member(stale), member,
                        // non-member]` arrangement that breaks
                        // contiguity between the two single-tab calls.
                        var leaveUpdates: [(tabId: Int, newToken: String?)] =
                            [(tab.guid, nil)]
                        if let partner = leavePartner {
                            leaveUpdates.append((partner.guid, nil))
                        }
                        browserState.applyOptimisticGroupMembership(
                            updates: leaveUpdates)
                    }
                }

                // Auto-join: TWO disjoint paths.
                //
                // 1. Sandwich — drop between two members of the
                //    same group (left and right post-move neighbors
                //    share that group's token, dragged tab isn't in
                //    that group). Cursor position is irrelevant for
                //    this case: the geometry already pins the tab
                //    inside the group's run.
                //
                // 2. Leading edge — drop on (or past) a group chip's
                //    right half. The drag controller already
                //    classified this during updateDragging by
                //    comparing the cursor against `chip.midX`:
                //    `context.targetGroupForLeadingJoin` is non-nil
                //    iff the cursor sat on/past chip.midX AND the
                //    dragged tab isn't already in that group. The
                //    same threshold drives the visual gap-after-chip
                //    rendering, so visual and commit agree. Drops in
                //    the strip's leading whitespace, on a chip's
                //    left half, or in the gap between two adjacent
                //    groups (cursor stayed before the next chip's
                //    midX) are all correctly EXcluded by the cursor
                //    gate — no further suppression is needed here.
                let postMoveIdx = (originalIndex < toIndex) ? max(0, toIndex - 1) : toIndex
                let postMoveTabs = browserState.normalTabs

                let sandwichToken: String? = {
                    guard postMoveIdx > 0,
                          postMoveIdx + 1 < postMoveTabs.count,
                          let leftToken = postMoveTabs[postMoveIdx - 1].groupToken,
                          let rightToken = postMoveTabs[postMoveIdx + 1].groupToken,
                          leftToken == rightToken,
                          leftToken != tab.groupToken else { return nil }
                    return leftToken
                }()

                let leadingEdgeToken: String? = context.targetGroupForLeadingJoin
                let trailingEdgeToken: String? = context.targetGroupForTrailingJoin

                let joinToken = sandwichToken ?? leadingEdgeToken ?? trailingEdgeToken
                // A tab opened from the bookmark bar carries the bookmark's
                // guid as `guidInLocalDB`; joining a group must graduate it
                // into a plain tab — drop the custom guid and clear the
                // Chromium-side custom value — but KEEP the bookmark in the
                // bar (the tab was only opened from it, not moved out of it).
                // `moveBookmarkIntoGroup` is the no-remove half of
                // `moveBookmarkOut`. Splits fall through to the generic path
                // so the partner pane travels too.
                if let token = joinToken,
                   let dbGuid = tab.guidInLocalDB,
                   browserState.splitGroup(forTabId: tab.guid) == nil,
                   let bookmark = browserState.bookmarkManager.bookmark(withGuid: dbGuid),
                   !bookmark.isFolder {
                    // `moveNormalTabLocally` above already placed the tab at
                    // the drop slot; reuse that resolved position
                    // (`moveBookmarkIntoGroup` re-seats via remove+insert, so
                    // the post-move index is idempotent).
                    let normalIndex = browserState.normalTabs
                        .firstIndex(where: { $0.guid == tab.guid }) ?? toIndex
                    let groupIndex = currentGroupRuns()
                        .first { $0.token == token }
                        .map { max(0, min(normalIndex - $0.range.lowerBound, $0.range.count)) } ?? 0
                    AppLogDebug(
                        "[TAB_GROUPS][STRIP_DRAG] bookmark auto-join " +
                        "windowId=\(browserState.windowId) bookmarkGuid=\(dbGuid) " +
                        "token=\(token) normalIndex=\(normalIndex)"
                    )
                    browserState.moveBookmarkIntoGroup(bookmark, toGroup: token,
                                                       groupIndex: groupIndex,
                                                       normalTabsIndex: normalIndex,
                                                       focusAfterCreate: tab.isActive)
                } else if let token = joinToken {
                    let kind: String = {
                        if sandwichToken != nil { return "sandwich" }
                        if leadingEdgeToken != nil { return "leadingEdge" }
                        return "trailingEdge"
                    }()
                    // Splits travel as a unit. When the dropped tab is in
                    // a non-pinned split, the partner pane joins the group
                    // with it so both panes share the token and stay
                    // adjacent — the merged in-group split row only
                    // renders when that invariant holds.
                    let splitPartner: Tab? = {
                        guard let group = browserState.splitGroup(forTabId: tab.guid),
                              !group.isPinned,
                              let partnerId = group.partnerTabId(of: tab.guid) else {
                            return nil
                        }
                        return browserState.tabs.first(where: { $0.guid == partnerId })
                    }()
                    var memberIds: [NSNumber] = [NSNumber(value: Int64(tab.guid))]
                    if let partner = splitPartner {
                        memberIds.append(NSNumber(value: Int64(partner.guid)))
                    }
                    AppLogDebug(
                        "[TAB_GROUPS][STRIP_DRAG] auto-join windowId=\(browserState.windowId) " +
                        "tabIds=\(memberIds) token=\(token) postMoveIdx=\(postMoveIdx) " +
                        "kind=\(kind)"
                    )
                    ChromiumLauncher.sharedInstance().bridge?.addTabsToGroup(
                        withWindowId: Int64(browserState.windowId),
                        tabIds: memberIds,
                        tokenHex: token
                    )
                    // Optimistic local update: the bridge returns
                    // synchronously but `tabJoinedGroup` rides the
                    // EventBus -> Task { @MainActor } async hop, so
                    // T.groupToken would still be stale (nil or old
                    // group) when the `performLayout(.dataChanged)`
                    // below runs. For sandwich auto-join that
                    // transient state has T sitting between GB's
                    // members with a non-GB token, splitting GB into
                    // two runs and tripping `currentGroupRuns()`'s
                    // contiguity assertion. Route through the batched
                    // `applyOptimisticGroupMembership(updates:)` so
                    // both panes of a split land adjacent to existing
                    // members atomically — single publish, no
                    // transient [member, member, intruder] state
                    // between the two single-tab calls.
                    var joinUpdates: [(tabId: Int, newToken: String?)] =
                        [(tab.guid, token)]
                    if let partner = splitPartner {
                        joinUpdates.append((partner.guid, token))
                    }
                    browserState.applyOptimisticGroupMembership(
                        updates: joinUpdates)
                }
            }
        }

        // Then reset the UI back to a clean non-drag layout.
        performLayout(context: .dataChanged)
        browserState.tabDraggingSession.end(screenLocation: screenPoint, dragOperation: .move)
    }

    /// Resolves the group token a single dropped pinned tab should join,
    /// or nil when the drop isn't onto a group. Leading/trailing edges
    /// reuse the drag controller's cursor-gated tokens (same thresholds
    /// as normal-tab auto-join); the interior (sandwich) case is derived
    /// geometrically from the drop index's neighbors.
    private func resolvePinnedDropGroupToken(context: TabDragContext, toIndex: Int) -> String? {
        if let token = context.targetGroupForLeadingJoin { return token }
        if let token = context.targetGroupForTrailingJoin { return token }
        let tabs = browserState.normalTabs
        if toIndex > 0, toIndex < tabs.count,
           let left = tabs[toIndex - 1].groupToken,
           let right = tabs[toIndex].groupToken,
           left == right {
            return left
        }
        return nil
    }

    func dragControllerDidCancelDrag() {
        clearDraggingPresentation(using: nil)
        browserState.tabDraggingSession.cancel(screenLocation: lastDragScreenPoint)
        pendingDropAction = nil
        clearExternalPreviewTarget()
        clearSplitHint()
        // Reset drag-related UI state.
        performLayout(context: .dataChanged)
    }

    func dragControllerConvertPointToLocal(_ windowPoint: CGPoint) -> CGPoint {
        return convert(windowPoint, from: nil)
    }

    /// Commits a split drop against the focused tab's page. When the focused
    /// tab is *not* a split, pairs the dragged tab with it into a new vertical
    /// split (dragged tab takes the dropped side; dragging the focused tab
    /// onto itself spawns a fresh new-tab-page partner). When the focused tab
    /// *is* a split, replaces the hovered pane with the dragged tab. The
    /// create/replace decision lives in `SplitTabDropContainer.commitSplitDrop`
    /// so both entry points stay identical.
    private func performSplitWithFocused(draggedTab: Tab,
                                         fromPinnedZone: Bool,
                                         zone: SplitTabDropContainer.DropZone) {
        guard browserState.splitGroup(forTabId: draggedTab.guid) == nil,
              let dropContainer = unsafeBrowserWindowController?.mainSplitViewController
                .webContentContainerViewController.splitTabDropContainer else { return }
        // A tab dragged out of the pinned zone must keep its pinned status:
        // route it as `.pinnedTab` so the drop demotes it into a normal split
        // (leaving a pinned placeholder at its slot), exactly as the
        // sidebar/vertical-layout drag does via the pasteboard. Passing
        // `.normalTab` here would form the split with the tab still pinned —
        // splits are never allowed to live in the pinned strip.
        let source: SplitTabDropContainer.DragSource
        if fromPinnedZone, let dbGuid = draggedTab.guidInLocalDB, !dbGuid.isEmpty {
            source = .pinnedTab(dbGuid: dbGuid)
        } else {
            source = .normalTab(tabId: draggedTab.guid)
        }
        dropContainer.commitSplitDrop(state: browserState,
                                      source: source,
                                      zone: zone)
    }

    private func handleExternalDrop(tab: Tab, context: TabDragContext, target: ExternalDropTarget) -> Bool {
        let targetState = target.windowController.browserState
        let clampedNormalIndex = min(max(0, target.index), targetState.normalTabs.count)
        let clampedPinnedIndex = min(max(0, target.index), browserState.pinnedTabs.count)

        switch target.zone {
        case .pinned:
            if context.sourceContainerType == .pinned {
                if let guid = tab.guidInLocalDB,
                   let pinnedTab = browserState.pinnedTabs.first(where: { $0.guidInLocalDB == guid }) {
                    browserState.movePinnedTab(tab: pinnedTab, to: clampedPinnedIndex, selectAfterMove: tab.isActive)
                }
            } else {
                browserState.moveNormalTab(tabId: tab.guid, toPinnd: clampedPinnedIndex, selectAfterMove: tab.isActive)
            }
            return moveTabToWindow(tab, targetState: targetState, scheduleNormalInsertion: false, index: clampedPinnedIndex)
        case .normal:
            if context.sourceContainerType == .pinned, let guid = tab.guidInLocalDB {
                browserState.movePinnedTabOut(pinnedGuid: guid, to: clampedNormalIndex, selectAfterMove: tab.isActive)
            }
            // JOIN intent — route through the group-aware bridge.
            // OUTSIDE intent (targetGroupToken == nil) — ordinary path.
            if let joinToken = target.targetGroupToken {
                return moveTabToWindowJoiningGroup(
                    tab,
                    targetState: targetState,
                    atIndex: clampedNormalIndex,
                    joinToken: joinToken,
                    anchorIsBefore: target.joinAnchorIsBefore
                )
            }
            return moveTabToWindow(tab, targetState: targetState, scheduleNormalInsertion: true, index: clampedNormalIndex)
        }
    }

    /// Refreshes layout only, skipping view-pool work to improve drag frame rate.
    private func updateLayoutOnly(
        container: NSView,
        viewPool: [String: TabItemView],
        tabs: [Tab],
        activeTab: Tab?,
        isPinned: Bool,
        excludedIndex: Int? = nil,
        excludedGroupRange: ClosedRange<Int>? = nil,
        excludedIndices: Set<Int> = [],
        gapIndex: Int?,
        gapWidth: CGFloat? = nil,
        pinnedSplitCollapsedIndices: Set<Int> = [],
        pinnedSplitWideIndices: Set<Int> = []
    ) {
        let combinedExcluded = excludedIndices.union(pinnedSplitCollapsedIndices)
        let layoutOutput = calculateLayout(
            containerWidth: container.bounds.width,
            tabs: tabs,
            activeTab: activeTab,
            isPinned: isPinned,
            excludedIndex: excludedIndex,
            excludedGroupRange: excludedGroupRange,
            excludedIndices: combinedExcluded,
            wideIndices: pinnedSplitWideIndices,
            gapIndex: gapIndex,
            gapWidth: gapWidth
        )

        applyLayout(
            container: container,
            viewPool: viewPool,
            layoutOutput: layoutOutput,
            tabs: tabs,
            activeTab: activeTab,
            isPinned: isPinned
        )
    }

    func updateDraggingViewPosition() {
        guard let context = dragController.context else { return }
        // Prefer the drag proxy, but fall back to the source view if needed.
        let draggingView = draggingProxyView
            ?? {
                let id = context.draggingTab.uniqueId
                switch context.sourceContainerType {
                case .pinned:
                    return pinnedTabViews[id]
                case .normal:
                    return normalTabViews[id]
                }
            }()
        guard let draggingView else { return }

        // Keep the dragged view above every other tab.
        draggingView.layer?.zPosition = 999

        // Update styling when the drag crosses between pinned and normal zones.
        updateDraggingPresentationIfNeeded(for: context.targetContainerType, tab: context.draggingTab)

        // Move the drag presentation with the pointer.
        let newFrame = dragPresentationFrame(for: context)

        // Apply the new frame without implicit animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        draggingView.frame = newFrame
        // Pin the partner proxy to the primary proxy at the same horizontal
        // offset captured at drag start so the pair reads as one unit.
        if let siblingProxy = draggingSiblingProxyView,
           let placement = draggingSiblingPlacement {
            siblingProxy.layer?.zPosition = 998
            var siblingFrame = siblingProxy.frame
            siblingFrame.size.height = newFrame.height
            siblingFrame.origin = CGPoint(
                x: newFrame.origin.x + placement.offsetX,
                y: newFrame.origin.y
            )
            siblingProxy.frame = siblingFrame
        }
        CATransaction.commit()

        // Keep the content-border active-tab gap in sync with the proxy on
        // plain drag-move ticks (when no sibling reflow fires onLayoutChanged).
        onLayoutChanged?()
    }

    private func updateDraggingPresentationIfNeeded(for zone: TabContainerType, tab: Tab) {
        guard draggingPresentationZone != zone else { return }
        draggingPresentationZone = zone

        // Only restyle the proxy; the source view stays hidden.
        guard let draggingView = draggingProxyView else { return }
        let splitInfo = splitRenderInfo(for: tab)
        // Merged-split source: keep the two-favicon rendering after the
        // restyle so a normal-merged cell dragged into the pinned zone (or
        // vice versa) doesn't collapse to a single-favicon proxy.
        let mergedPartner = draggingMergedPartner
        let renderData = TabRenderData(
            id: tab.uniqueId,
            title: tab.title,
            url: tab.url ?? "",
            isActive: isTabActive(tab, activeTab: browserState.focusingTab),
            isPinned: zone == .pinned,
            splitPairPosition: mergedPartner == nil ? splitInfo.position : nil,
            isSplitGroupActive: mergedPartner == nil ? splitInfo.groupActive : false,
            pinnedSplitPartner: mergedPartner,
            sourceTab: tab
        )
        draggingView.configure(with: renderData)
        draggingView.layoutSubtreeIfNeeded()
        cachedTabDragImage = draggingView.createDraggingSnapshot(cornerRadius: TabStripMetrics.Tab.cornerRadius)
    }

    private func dragPresentationFrame(for context: TabDragContext) -> CGRect {
        // Resolve pointer positions in tab-strip coordinates.
        let currentPoint = convert(context.currentMouseLocation, from: nil)
        let initialPoint = convert(context.initialMouseLocation, from: nil)
        // Preserve the pointer offset so width changes do not cause visual jumps.
        let rawOffsetX = initialPoint.x - context.initialTabFrame.minX
        let rawOffsetY = initialPoint.y - context.initialTabFrame.minY
        var frame = context.initialTabFrame

        switch context.targetContainerType {
        case .pinned:
            // Pinned tabs use a fixed width and centered height. Merged
            // split cells span both panes' slots (mirrors layoutPinned's
            // wideWidth) so the proxy matches what the drop will produce.
            let pinnedWidth = draggingMergedPartner == nil
                ? TabStripMetrics.PinnedTab.width
                : TabStripMetrics.PinnedTab.width * 2 + TabStripMetrics.PinnedTab.spacing
            frame.size = CGSize(width: pinnedWidth, height: TabStripMetrics.PinnedTab.height)
        case .normal:
            // Normal tabs use the current average tab width.
            let width = max(
                TabStripMetrics.Tab.minWidth,
                averageNormalTabWidth(excluding: context.draggingTab)
            )
            frame.size = CGSize(width: width, height: TabStripMetrics.Strip.tabHeight)
        }

        // Anchor the x-position to the pointer offset to avoid cross-zone jumps.
        let clampedOffsetX = min(max(rawOffsetX, 0), max(1, frame.width) - 1)
        let clampedOffsetY = min(max(rawOffsetY, 0), max(1, frame.height) - 1)
        let combinedFrame = pinnedContainer.frame.union(normalContainer.frame)

        if !combinedFrame.contains(currentPoint) {
            frame.origin.x = currentPoint.x - clampedOffsetX
            frame.origin.y = currentPoint.y - clampedOffsetY
            return frame
        }

        frame.origin.x = currentPoint.x - clampedOffsetX
        switch context.targetContainerType {
        case .pinned:
            frame.origin.y = pinnedContainer.frame.minY
                + (TabStripMetrics.Strip.tabHeight - TabStripMetrics.PinnedTab.height) / 2.0
        case .normal:
            frame.origin.y = normalContainer.frame.minY + TabStripMetrics.Strip.bottomSpacing
        }
        // Clamp drag proxy within the combined pinned + normal bounds,
        // and never exceed the left edge of the New Tab button.
        //
        // Exception: when the dragged tab is itself the strip's
        // rightmost tab AND belongs to a group, the natural clamp
        // pins the proxy near its source position because the
        // trailing-edge drag gap pushes the New Tab button right by
        // ~one tab width. With the proxy effectively immovable, the
        // user has no visual room to express "drag out of group via
        // the trailing edge". Use the strip's right edge as the
        // clamp instead — the proxy may briefly overlap the New Tab
        // button while dragging, which is acceptable for the
        // duration of an active drag.
        let padding: CGFloat = 6
        let minX = combinedFrame.minX + padding
        let isRightmostGrouped = (context.sourceContainerType == .normal
            && context.draggingTab.groupToken != nil
            && context.sourceIndex == browserState.normalTabs.count - 1)
        let rightLimit = isRightmostGrouped
            ? combinedFrame.maxX - padding
            : min(combinedFrame.maxX, newTabButton.frame.minX) - padding
        let maxX = rightLimit - frame.width
        if minX <= maxX {
            // Soft clamp for a slight elastic feel at the edges.
            let overshootLimit: CGFloat = 8
            let overshootFactor: CGFloat = 0.35
            if frame.origin.x < minX {
                let delta = min(minX - frame.origin.x, overshootLimit)
                frame.origin.x = minX - delta * overshootFactor
            } else if frame.origin.x > maxX {
                let delta = min(frame.origin.x - maxX, overshootLimit)
                frame.origin.x = maxX + delta * overshootFactor
            }
        } else {
            frame.origin.x = minX
        }

        return frame
    }

    private func averageNormalTabWidth(excluding tab: Tab) -> CGFloat {
        // Use current laid-out normal-tab widths as the drag-width reference.
        let frames = browserState.normalTabs.compactMap { item -> CGRect? in
            guard item !== tab else { return nil }
            let frame = normalTabViews[item.uniqueId]?.frame ?? .zero
            return frame == .zero ? nil : frame
        }
        guard !frames.isEmpty else {
            return TabStripMetrics.Tab.idealWidth
        }
        let totalWidth = frames.reduce(0) { $0 + $1.width }
        return totalWidth / CGFloat(frames.count)
    }

    private func clearDraggingPresentation(using context: TabDragContext?) {
        if let sourceView = draggingSourceView {
            // Snap the source view to the drop point before revealing it.
            if let context,
               context.targetContainerType == context.sourceContainerType,
               let proxy = draggingProxyView {
                let targetContainer = (context.sourceContainerType == .pinned) ? pinnedContainer : normalContainer
                let frameInStrip = convert(proxy.frame, from: dragOverlay)
                let frameInContainer = targetContainer.convert(frameInStrip, from: self)

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                sourceView.frame = frameInContainer
                CATransaction.commit()
            }
            // Reveal the source view again.
            sourceView.alphaValue = 1
        }
        // Reveal the split partner's source view too — it was hidden while
        // its proxy was lifted in the overlay.
        if let siblingSourceView = draggingSiblingSourceView {
            if let context,
               context.targetContainerType == context.sourceContainerType,
               let siblingProxy = draggingSiblingProxyView,
               context.sourceContainerType == .normal {
                let frameInStrip = convert(siblingProxy.frame, from: dragOverlay)
                let frameInContainer = normalContainer.convert(frameInStrip, from: self)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                siblingSourceView.frame = frameInContainer
                CATransaction.commit()
            }
            siblingSourceView.alphaValue = 1
        }
        // Clear proxy views and cached drag state.
        draggingProxyView?.removeFromSuperview()
        draggingProxyView = nil
        draggingSiblingProxyView?.removeFromSuperview()
        draggingSiblingProxyView = nil
        draggingSourceView = nil
        draggingSiblingSourceView = nil
        draggingSiblingPlacement = nil
        draggingPresentationZone = nil
        draggingMergedPartner = nil
        dragOverlay.isHidden = true
        hideFloatingDragPreview()
        cachedTabDragImage = nil
        cachedPageDragImage = nil
    }
}

// MARK: - TabGroupDragDelegate
extension TabStrip: TabGroupDragDelegate {
    func groupDragControllerSnapshot(token: String) -> TabGroupDragStartSnapshot? {
        let runs = currentGroupRuns()
        guard let run = runs.first(where: { $0.token == token }) else {
            AppLogWarn("[TabGroupDrag] snapshot: token not in current runs token=\(token)")
            return nil
        }
        guard let chipView = chipViews[token], chipView.superview != nil else {
            AppLogWarn("[TabGroupDrag] snapshot: chip view missing token=\(token)")
            return nil
        }
        // GroupRun.range is ClosedRange<Int>; convert to half-open Range<Int>
        // for `TabGroupDragContext.sourceRange`.
        let sourceRange = run.range.lowerBound..<(run.range.upperBound + 1)
        let members = Array(browserState.normalTabs[run.range]).map { $0.guid }

        // Bring chipView.frame into normalTabFrames space (scroll offset
        // is subtracted from chip.frame in `applyChipPlacements`, but
        // metrics' normalTabFrames add it back; mirror that).
        let chipFramePostRelayout = chipView.frame.offsetBy(dx: currentScrollOffset, dy: 0)
        // If onDragStart captured the chip's pre-temp-collapse position,
        // anchor the snapshot to that position so the chip's visual
        // origin stays under the user's grab point. `chipPositionShift`
        // = how far the chip's natural slot slid during the temp-collapse
        // relayout; consumed by `applyGroupDragTransforms` to compensate
        // the transform delta. Single-shot consume: clear the ivar so a
        // stale value can't leak into a later drag.
        let chipFrameInMetricsSpace: CGRect
        let chipPositionShift: CGFloat
        if let prePostMinX = chipPreCollapseMetricsMinXForDrag {
            chipPositionShift = chipFramePostRelayout.minX - prePostMinX
            chipFrameInMetricsSpace = CGRect(
                x: prePostMinX,
                y: chipFramePostRelayout.minY,
                width: chipFramePostRelayout.width,
                height: chipFramePostRelayout.height
            )
        } else {
            chipPositionShift = 0
            chipFrameInMetricsSpace = chipFramePostRelayout
        }
        chipPreCollapseMetricsMinXForDrag = nil

        let metrics = dragControllerRequestMetrics()
        let frames = metrics.normalTabFrames

        let sliceWidth: CGFloat
        if run.isCollapsed {
            sliceWidth = chipFrameInMetricsSpace.width
        } else {
            // run.range is in normalTabs index space — same as normalTabFrames.
            let upper = min(run.range.upperBound, frames.count - 1)
            let lastMemberMaxX = (run.range.lowerBound...upper).reduce(chipFrameInMetricsSpace.maxX) { acc, idx in
                max(acc, frames[idx].maxX)
            }
            sliceWidth = lastMemberMaxX - chipFrameInMetricsSpace.minX
        }

        // ── Pre-compute snap candidates for the entire drag. Use the
        //    natural pre-drag frames (this method runs before any
        //    layout transition) and adjust positions for tabs AFTER
        //    the source range — in the during-drag excluded layout
        //    those tabs slide left by `sliceWidth` to fill the slice's
        //    space. Pre-shifting here gives each candidate a stable
        //    `x` that equals where the slice's left edge would land
        //    post-commit, regardless of which side of the natural-vs-
        //    excluded layout transition the drag is currently in.
        let count = browserState.normalTabs.count
        let naturalSliceLeftX = chipFrameInMetricsSpace.minX
        var foreignRunStartToken: [Int: String] = [:]
        var insideForeign: Set<Int> = []
        for r in runs where r.token != token {
            foreignRunStartToken[r.range.lowerBound] = r.token
            if r.range.lowerBound + 1 <= r.range.upperBound {
                for i in (r.range.lowerBound + 1)...r.range.upperBound {
                    insideForeign.insert(i)
                }
            }
        }
        let chipByToken: [String: CGRect] = Dictionary(
            uniqueKeysWithValues: metrics.chipFrames.map { ($0.token, $0.frame) }
        )

        // Adjustment helper: tabs and chips at indices >= sourceRange's
        // upper bound shift left by sliceWidth in the excluded layout.
        func shifted(_ x: CGFloat, atOrAfterSource: Bool) -> CGFloat {
            return atOrAfterSource ? x - sliceWidth : x
        }

        var snapCandidates: [(index: Int, x: CGFloat)] = []
        for insertion in 0...count {
            if insideForeign.contains(insertion) { continue }
            let x: CGFloat
            if insertion >= sourceRange.lowerBound && insertion <= sourceRange.upperBound {
                // No-op zone: any drop here is a no-op; anchor to the
                // chip's natural drag-start position so cursor hovering
                // near source keeps targetIndex inside the source range.
                x = naturalSliceLeftX
            } else if let foreignToken = foreignRunStartToken[insertion],
                      let chipFrame = chipByToken[foreignToken] {
                // Foreign group's chip — slice lands BEFORE the chip.
                x = shifted(chipFrame.minX, atOrAfterSource: insertion >= sourceRange.upperBound)
            } else if insertion == 0 {
                // Slice at very start of strip. Use the leftmost minX
                // of any non-source tab or non-dragging chip.
                var leftmost = CGFloat.infinity
                for (i, f) in frames.enumerated() where !sourceRange.contains(i) && f != .zero {
                    leftmost = min(leftmost, f.minX)
                }
                for cf in metrics.chipFrames where cf.token != token {
                    leftmost = min(leftmost, cf.frame.minX)
                }
                x = leftmost == CGFloat.infinity ? metrics.normalContainerFrame.minX : leftmost
            } else if insertion >= count {
                // Slice at very end of strip. Use the largest excluded-
                // layout maxX of any non-source tab, AND any non-dragging
                // chip (the chip can be the strip's last visible element
                // when a trailing group is collapsed and its member is
                // zero-width).
                var endX: CGFloat = -.infinity
                for (i, f) in frames.enumerated() where !sourceRange.contains(i) && f != .zero {
                    let candidateMaxX = shifted(f.maxX, atOrAfterSource: i >= sourceRange.upperBound)
                    endX = max(endX, candidateMaxX)
                }
                for cf in metrics.chipFrames where cf.token != token {
                    let atOrAfterSource = cf.firstMemberIndex >= sourceRange.upperBound
                    let candidateMaxX = shifted(cf.frame.maxX, atOrAfterSource: atOrAfterSource)
                    endX = max(endX, candidateMaxX)
                }
                x = endX == -.infinity ? naturalSliceLeftX : endX
            } else if insertion < sourceRange.lowerBound,
                      insertion < frames.count, frames[insertion] != .zero {
                // Before source — no shift.
                x = frames[insertion].minX
            } else if insertion < frames.count, frames[insertion] != .zero {
                // After source — shift left by sliceWidth.
                x = shifted(frames[insertion].minX, atOrAfterSource: true)
            } else {
                x = naturalSliceLeftX
            }
            snapCandidates.append((insertion, x))
        }

        let firstNormalSlotX: CGFloat = {
            // Seed with naturalSliceLeftX so when the slice itself is
            // at the strip's leftmost position (= no non-source tab
            // sits to its left) we still get the correct leftmost
            // anchor — not the leftmost non-source tab's minX which
            // could be far to the right of the slice.
            var leftmost = naturalSliceLeftX
            for (i, f) in frames.enumerated() where !sourceRange.contains(i) && f != .zero {
                leftmost = min(leftmost, f.minX)
            }
            for cf in metrics.chipFrames where cf.token != token {
                leftmost = min(leftmost, cf.frame.minX)
            }
            return leftmost
        }()

        return TabGroupDragStartSnapshot(
            memberTabIds: members,
            sourceRange: sourceRange,
            chipFrame: chipFrameInMetricsSpace,
            sliceWidth: sliceWidth,
            isCollapsed: run.isCollapsed,
            snapCandidates: snapCandidates,
            firstNormalSlotX: firstNormalSlotX,
            chipPositionShift: chipPositionShift
        )
    }

    func groupDragControllerDidUpdate() {
        if groupDragController.context == nil {
            // Drag finished (context just transitioned to nil via one
            // of endDragging's commit branches: .local / .external /
            // .tearOff). Animate the settling so the final reflow
            // slides in rather than snaps.
            releaseTemporaryCollapseIfNeeded()
            animateGroupDragSettle()
        } else {
            // Active drag: `layout()` reads the live group context and
            // wraps `updateLayoutOnly` in NSAnimationContext so the
            // non-dragged tabs' frame changes animate while the
            // dragged chip's transform stays instant via the
            // CATransaction.setDisableActions wrapper there.
            needsLayout = true
        }
    }

    /// Animated cleanup pass to run when a whole-group drag ends
    /// (commit / cancel / rejected / liveness abort). Runs the
    /// transform reset (`applyGroupDragTransforms(context: nil)`) and
    /// the data-rebind pass (`rebindData`) inside a single
    /// `NSAnimationContext` so the chip's `layer.transform` interpolates
    /// from its last drag value back to identity in lockstep with the
    /// view frames sliding to their post-commit positions. Without
    /// this, the transform would reset on a later layout pass after
    /// the frame animation already played, snapping the chip mid-flight.
    ///
    /// `groupDragSettling` gates `layout()` for the duration so any
    /// pending `needsLayout = true` from the last `continueDragging`
    /// tick can't race in with an instant frame reset and cancel the
    /// in-flight animation.
    /// Aborts an in-flight `animateGroupDragSettle` immediately. Called
    /// when a new whole-group drag is about to start while the previous
    /// drag's settle is still animating (user dropped one drag and
    /// began another within ~180ms).
    ///
    /// Three things must happen before the new drag's setup code runs:
    ///   1. Clear `groupDragSettling` so `layout()`'s middle branch no
    ///      longer skips the upcoming `layoutSubtreeIfNeeded()` pass —
    ///      otherwise the snapshot reads stale geometry.
    ///   2. Bump `groupDragSettleGeneration` so the prior settle's
    ///      completion handler (still scheduled to fire) sees its
    ///      generation as stale and no-ops, leaving the new drag's
    ///      state untouched.
    ///   3. Remove in-flight CA animations on chip + tab layers. CA
    ///      animations aren't cancelled by `setDisableActions(true)` or
    ///      by setting the same property to a new value — they run to
    ///      their own programmed `toValue` and ignore subsequent model
    ///      writes. Without this, the new drag's `applyGroupDragTransforms`
    ///      would set `layer.transform = translation(deltaX)` on the
    ///      model layer, but the presentation layer would still be
    ///      animating toward the old settle's `identity` target. Chip
    ///      wouldn't visibly track the cursor until the stale animation
    ///      ends.
    ///
    /// `removeAllAnimations()` may also clear unrelated animations
    /// (e.g., a brand-new tab's alpha fade-in). Within the 180ms
    /// post-drop window the only realistic animations attached to
    /// these layers are this settle's own, so the collateral cost is
    /// negligible.
    private func cancelInFlightGroupDragSettle() {
        guard groupDragSettling else { return }
        groupDragSettleGeneration += 1
        groupDragSettling = false
        for view in normalTabViews.values {
            view.layer?.removeAllAnimations()
        }
        for chip in chipViews.values {
            chip.layer?.removeAllAnimations()
        }
        AppLogDebug(
            "[TAB_GROUPS][GROUP_DRAG] cancelInFlightGroupDragSettle " +
            "(generation=\(groupDragSettleGeneration))"
        )
    }

    private func animateGroupDragSettle() {
        groupDragSettleGeneration += 1
        let myGeneration = groupDragSettleGeneration
        groupDragSettling = true
        let cfg = TabStripAnimationConfig.config(for: .dataChanged)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = cfg.duration
            ctx.timingFunction = cfg.timingFunction
            ctx.allowsImplicitAnimation = cfg.allowsImplicitAnimation
            applyGroupDragTransforms(context: nil)
            rebindData()
        }, completionHandler: { [weak self] in
            guard let self else { return }
            // Stale completion guard: a newer settle bumped the
            // generation while this one was in flight (user dropped
            // a second drag inside the 0.18s window). The newer
            // settle owns the state now; this completion would
            // wrongly clear `groupDragSettling` and let the next
            // layout() snap the live animation.
            guard self.groupDragSettleGeneration == myGeneration else { return }
            self.groupDragSettling = false
            // Re-arm a normal (instant) layout pass so any state that
            // accumulated during the settle window (e.g., scroll, mask
            // updates) gets a clean reapply.
            self.needsLayout = true
        })
    }

    /// Clears `temporarilyCollapsedGroupTokenForDrag` if set, refreshes
    /// the chip's cached full width so the layout engine picks up the
    /// restored (expanded) measurement, and lets the caller drive the
    /// `needsLayout = true` that re-renders the strip. Safe to call
    /// when the flag is nil or when the source group has already left
    /// the strip (cross-window / tear-off committed) — `refreshChipWidth`
    /// no-ops cleanly in that case via its `browserState.groups[token]`
    /// guard.
    private func releaseTemporaryCollapseIfNeeded() {
        guard let token = temporarilyCollapsedGroupTokenForDrag else { return }
        temporarilyCollapsedGroupTokenForDrag = nil
        refreshChipWidth(for: token)
        AppLogDebug(
            "[TAB_GROUPS][GROUP_DRAG] releaseTemporaryCollapse token=\(token)"
        )
    }

    func groupDragControllerCommitMove(memberTabIds: [Int], to: Int) {
        // `BrowserState.moveNormalTabSlice` and the controller's
        // `endDragging` both log their own commit lines; no need for
        // a redundant log here.
        browserState.moveNormalTabSlice(memberIds: memberTabIds, to: to)
    }

    func groupDragControllerCommitMoveCrossWindow(
        memberTabIds: [Int],
        targetWindowController: MainBrowserWindowController,
        atIndex: Int
    ) {
        browserState.moveGroupSliceToWindow(
            memberIds: memberTabIds,
            targetState: targetWindowController.browserState,
            atIndex: atIndex
        )
    }

    func groupDragControllerCommitTearOff(
        memberTabIds: [Int],
        dropScreenLocation: CGPoint
    ) {
        browserState.moveGroupSliceToNewWindow(
            memberIds: memberTabIds,
            dropScreenLocation: dropScreenLocation
        )
    }

    func groupDragControllerDidCancel() {
        // Covers .rejected (endDragging) and cancelDragging (Esc /
        // mid-drag liveness abort). Mirror the cleanup from
        // didUpdate's nil-context branch so the temp-collapse overlay
        // and chip transforms also clear here — didCancel is the only
        // callback fired in these paths.
        releaseTemporaryCollapseIfNeeded()
        animateGroupDragSettle()
        removeGroupDragEscMonitor()
    }

    func groupDragControllerCurrentNormalTabOrder() -> [Int] {
        // normalTabOrder is private; normalTabs (its derived array)
        // is exposed and 1:1 in guid order — same liveness signal.
        return browserState.normalTabs.map { $0.guid }
    }

    func groupDragControllerCurrentScreenPoint() -> CGPoint? {
        return lastDragScreenPoint
    }

    func groupDragControllerResolveExternalDropTarget(screenPoint: CGPoint) -> ExternalGroupDropTarget? {
        // Step 1: locate a candidate target window + its tab strip,
        // reusing the same single-tab cross-window acceptance check.
        guard let (targetWindowController, targetStrip) =
                visibleExternalTabStripTarget(for: screenPoint) else {
            return nil
        }
        // Step 2: ask the target strip for a group-aware drop hit-test.
        // Returns nil on pinned-zone hit (groups can't land there) or
        // when the cursor falls outside both pinned and normal containers.
        guard let target = targetStrip.groupDropTarget(forScreenPoint: screenPoint) else {
            return nil
        }
        // Step 3: groups never land in pinned region — additional
        // belt-and-suspenders (groupDropTarget already filters pinned).
        guard target.zone == .normal else { return nil }
        return ExternalGroupDropTarget(
            windowController: targetWindowController,
            zone: target.zone,
            index: target.index
        )
    }

    func groupDragControllerIsInsideDragBoundary(screenPoint: CGPoint) -> Bool {
        return isInsideDragBoundary(screenPoint)
    }

    func groupDragControllerIsOverAnotherBrowserStrip(screenPoint: CGPoint) -> Bool {
        // `visibleExternalTabStripTarget` resolves a non-source window
        // whose strip's drag boundary contains the cursor (and that
        // accepts cross-window drag). It does NOT validate the
        // specific zone — that's the caller's job via `groupDropTarget`.
        // So a `nil` external target + non-nil `visibleExternalTabStripTarget`
        // means "over another window's strip, but the target zone
        // refused" → rejection path.
        return visibleExternalTabStripTarget(for: screenPoint) != nil
    }

    // MARK: - Group-aware cross-window drop hit-test

    /// Resolve a screen point to a `(.normal, index)` insertion target
    /// in **this** strip's `normalTabs` coordinate space, with group
    /// boundary snapping applied. Returns `nil` when:
    ///   - cursor falls outside both pinned and normal containers
    ///   - cursor lands in the pinned region (groups cannot be pinned)
    ///
    /// Two-pass detection (per 2026-05-12 plan §Task 2.4):
    ///   - **Pass 1**: chip frame hit-test. If cursor lands directly on
    ///     a chip, midX-split decides whether to snap to the run's
    ///     leading edge (`lowerBound`) or trailing edge (`upperBound + 1`).
    ///   - **Pass 2**: raw-index hit-test via single-tab `calculateGapIndex`.
    ///     If the raw index would split an existing group's run interior
    ///     (`lowerBound < index <= upperBound`), snap to the closer
    ///     boundary.
    ///
    /// Used by both `groupDragControllerResolveExternalDropTarget` (cross-
    /// window arrival side) and — in future Task 4 — the matching same-
    /// strip group-aware path if needed. Single-tab drag continues to use
    /// `dropTarget(forScreenPoint:)` and is unaffected.
    func groupDropTarget(forScreenPoint screenPoint: CGPoint) -> (zone: TabContainerType, index: Int)? {
        guard let window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: NSPoint(x: screenPoint.x, y: screenPoint.y))
        let localPoint = convert(windowPoint, from: nil)
        let metrics = dragControllerRequestMetrics()

        // Reject pinned zone — groups cannot live in the pinned region.
        if metrics.pinnedContainerFrame.contains(localPoint) {
            return nil
        }
        // Cursor outside the normal container too → caller decides what
        // to do (single-tab uses end-of-strip; for cross-window group
        // we conservatively return nil so the controller routes to
        // .tearOff via the boundary check instead).
        guard metrics.normalContainerFrame.contains(localPoint) else {
            return nil
        }

        // Project to "normal container space + scroll" — same space as
        // `chipFrames` and `normalTabFrames` (both have scrollOffset
        // added back via `offsetBy(dx: currentScrollOffset, ...)` in
        // dragControllerRequestMetrics).
        let normalX = localPoint.x - metrics.normalContainerFrame.minX + metrics.normalScrollOffset

        // Pass 1 — chip hit-test. chipFrames is keyed by group token and
        // carries firstMemberIndex / lastMemberIndex of the run.
        for cf in metrics.chipFrames {
            // Single-row strip → only x-range matters; chip.frame is
            // pre-offsetBy-scroll so .minX / .maxX live in normalX space.
            guard cf.frame.minX <= normalX, normalX < cf.frame.maxX else { continue }
            if normalX < cf.frame.midX {
                return (.normal, cf.firstMemberIndex)        // left half  → run start
            } else {
                return (.normal, cf.lastMemberIndex + 1)     // right half → run end + 1
            }
        }

        // Pass 2 — raw index via single-tab gap calculation, then check
        // whether the index would split a group run. localX is in the
        // single-tab tabFrames coord (pre-offsetBy-scroll), so pass
        // it through the same form the existing `dropTarget` does.
        let rawIndex = calculateGapIndex(
            localX: normalX,
            tabFrames: metrics.normalTabFrames,
            excludedIndex: nil
        )

        // If rawIndex falls strictly inside a group run, snap to the
        // closer boundary. Insertion semantics: index k means "insert
        // between tabs at k-1 and k". Interior iff k ∈ (lowerBound,
        // upperBound]. Boundaries: lowerBound (before first member)
        // and upperBound + 1 (after last member).
        let runs = currentGroupRuns()
        if let run = runs.first(where: { rawIndex > $0.range.lowerBound && rawIndex <= $0.range.upperBound }) {
            let distToStart = rawIndex - run.range.lowerBound
            let distToEnd = run.range.upperBound + 1 - rawIndex
            return (.normal, (distToStart <= distToEnd) ? run.range.lowerBound : run.range.upperBound + 1)
        }

        return (.normal, rawIndex)
    }

    // MARK: - Single-tab cross-window resolver

    /// Resolves a screen point to a cross-window single-tab drop intent
    /// in THIS strip's coordinate space. Cross-window analog of
    /// `TabStripDragController`'s same-window heuristics
    /// (TabStripDragController.swift:220-485), using a "virtual D"
    /// (cursor-centered frame of idealTabWidth) instead of the live
    /// dragged proxy — so the JOIN/OUTSIDE flip happens on D-edge
    /// crossings, not cursor center. See spec §3.2-§3.3.
    ///
    /// Per-chip prev-state hysteresis is anchored on this strip's
    /// `externalHoverGapBeforeChipToken`. Cross-window cannot reuse
    /// `TabDragContext.gapBeforeRunStartChipToken` because that lives
    /// on the source-side context; the target strip has no such
    /// context.
    ///
    /// Returns nil when the cursor falls outside both pinned and normal
    /// containers (caller routes to tear-off).
    private func resolveSingleTabDropIntent(forScreenPoint screenPoint: CGPoint) -> SingleTabDropIntent? {
        guard let window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: NSPoint(x: screenPoint.x, y: screenPoint.y))
        let localPoint = convert(windowPoint, from: nil)
        let metrics = dragControllerRequestMetrics()

        // Pinned region: never a JOIN (groups don't live in pinned).
        if metrics.pinnedContainerFrame.contains(localPoint) {
            let localX = localPoint.x - metrics.pinnedContainerFrame.minX
            let idx = calculateGapIndex(localX: localX,
                                        tabFrames: metrics.pinnedTabFrames,
                                        excludedIndex: nil)
            externalHoverGapBeforeChipToken = nil
            return SingleTabDropIntent(zone: .pinned,
                                       index: idx,
                                       joinGroupToken: nil,
                                       joinAnchorIsBefore: true)
        }

        guard metrics.normalContainerFrame.contains(localPoint) else {
            externalHoverGapBeforeChipToken = nil
            return nil
        }

        // Project to normalContainer + scroll coords (same space as
        // metrics.chipFrames and metrics.normalTabFrames).
        let normalX = localPoint.x - metrics.normalContainerFrame.minX + metrics.normalScrollOffset
        let tabW = TabStripMetrics.Tab.idealWidth
        let virtualDMinX = normalX - tabW / 2
        let virtualDMaxX = normalX + tabW / 2

        let runs = currentGroupRuns()
        let collapsedTokens = Set(runs.filter { $0.isCollapsed }.map { $0.token })

        // Compute rawIndex up front; chip anchor selection keys on it
        // so the chip stays anchored through let-way. Earlier overlap-
        // based selection (gating Pass 1 on `virtualD overlaps chip`)
        // oscillated: after let-way fires, the chip slides right by
        // gap_width and no longer overlaps the cursor — the overlap
        // gate would then clear the prev-state token, and the next
        // frame's "first-frame" branch flips ON again with the natural
        // chip frame. Each cursor sample = one chip flip = visible
        // flicker. See same-window's `TabStripDragController:197-199`
        // for the precedent (`leadingChip = firstMemberIndex ==
        // targetIndex`); same-window's `targetIndex` is stable through
        // let-way because the gap is reserved at `firstMemberIndex`
        // and `calculateGapIndex` keeps the cursor pinned to it.
        let rawIndex = calculateGapIndex(
            localX: normalX,
            tabFrames: metrics.normalTabFrames,
            excludedIndex: nil
        )

        // Pass 1: leadingChip-driven prev-state hysteresis (foreign-
        // chip path; cross-window has no own-chip case since the
        // dragged tab lives in another strip).
        //
        // Collapsed chips are skipped — dropping into a collapsed
        // group's interior makes no UX sense (no visible run). The
        // hover-expand timer in `updateExternalDragPreview` detects
        // collapsed-chip hover separately and expands after 300ms;
        // the next resolver call (post-expand) treats the chip as
        // expanded and resolves normally. See spec §6.
        let leadingChip: TabStripChipFrame? = metrics.chipFrames.first(where: {
            $0.firstMemberIndex == rawIndex && !collapsedTokens.contains($0.token)
        })

        if let cf = leadingChip {
            let prevForThisChip = (externalHoverGapBeforeChipToken == cf.token)
            let gapBeforeChipNow: Bool
            if prevForThisChip {
                // Was "before chip" — chip currently slid right. Flip
                // OFF when D's right edge moves past the (slid)
                // chip.midX.
                gapBeforeChipNow = virtualDMaxX < cf.frame.midX
            } else {
                // First frame on this chip / was "after chip". Flip
                // ON when D's left edge meets the (natural) chip.midX.
                gapBeforeChipNow = virtualDMinX <= cf.frame.midX
            }
            externalHoverGapBeforeChipToken = gapBeforeChipNow ? cf.token : nil
            if gapBeforeChipNow {
                // OUTSIDE: snap to run.lowerBound; no JOIN.
                return SingleTabDropIntent(zone: .normal,
                                           index: cf.firstMemberIndex,
                                           joinGroupToken: nil,
                                           joinAnchorIsBefore: true)
            } else {
                // leadingJoin: become new first member.
                return SingleTabDropIntent(zone: .normal,
                                           index: cf.firstMemberIndex,
                                           joinGroupToken: cf.token,
                                           joinAnchorIsBefore: true)
            }
        }
        externalHoverGapBeforeChipToken = nil

        // Pass 2: raw-index resolution for sandwich + trailingJoin.

        // 2a. Sandwich: rawIndex strictly inside some run's interior
        // (lowerBound < idx <= upperBound). Anchor = tab at rawIndex
        // (insert BEFORE it).
        if let run = runs.first(where: {
            rawIndex > $0.range.lowerBound && rawIndex <= $0.range.upperBound
        }) {
            return SingleTabDropIntent(zone: .normal,
                                       index: rawIndex,
                                       joinGroupToken: run.token,
                                       joinAnchorIsBefore: true)
        }

        // 2b. trailingJoin: rawIndex == run.upperBound + 1 AND virtual D
        // covers run's last member z by at least 1/3. Mirrors
        // TabStripDragController:462-485. Anchor = run's last member
        // (insert AFTER it).
        for run in runs {
            guard rawIndex == run.range.upperBound + 1 else { continue }
            guard run.range.upperBound < metrics.normalTabFrames.count else { continue }
            let zFrame = metrics.normalTabFrames[run.range.upperBound]
            guard zFrame != .zero, zFrame.width > 0 else { continue }
            let third = zFrame.width / 3
            guard virtualDMaxX >= zFrame.minX + third,
                  virtualDMinX <= zFrame.maxX - third else { continue }
            return SingleTabDropIntent(zone: .normal,
                                       index: rawIndex,
                                       joinGroupToken: run.token,
                                       joinAnchorIsBefore: false)
        }

        // OUTSIDE: rawIndex unchanged, no JOIN.
        return SingleTabDropIntent(zone: .normal,
                                   index: rawIndex,
                                   joinGroupToken: nil,
                                   joinAnchorIsBefore: true)
    }

    // MARK: - Esc cancel (group drag only)

    /// Installs a process-local keyDown monitor that cancels the
    /// active group drag on Esc (keyCode 53). Single-tab drag is
    /// untouched — it has its own cancel paths via the existing
    /// drag controller.
    fileprivate func installGroupDragEscMonitor() {
        guard groupDragEscMonitor == nil else { return }
        groupDragEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }
            guard event.keyCode == 53 else { return event }
            // Eat the event so other handlers (e.g. menus) don't react.
            AppLogDebug("[TabGroupDrag] Esc captured → cancelDragging")
            // Snapshot before cancelDragging clears the context — same
            // pattern as onDragEnd. Restore source visuals + clear
            // floating preview / external preview after cancel.
            let dragSnapshot = self.groupDragController.context.map {
                (token: $0.draggingChipToken, memberIds: $0.memberTabIds)
            }
            self.groupDragController.cancelDragging()
            self.removeGroupDragEscMonitor()
            self.hideFloatingDragPreview()
            if let snap = dragSnapshot {
                self.restoreSourceGroupVisuals(token: snap.token, memberIds: snap.memberIds)
            }
            self.clearExternalPreviewTarget()
            return nil
        }
    }

    fileprivate func removeGroupDragEscMonitor() {
        if let monitor = groupDragEscMonitor {
            NSEvent.removeMonitor(monitor)
            groupDragEscMonitor = nil
        }
    }
}
