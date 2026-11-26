// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Hosts two to four Chromium native views as columns (or rows) with a
/// draggable divider between each neighbouring pair. Pure view — owns no
/// model state; the owning controller pushes updates in and observes
/// drag-end via `onFractionsCommit`.
///
/// Chromium is source of truth for the pane shares: every drag-end calls
/// `onFractionsCommit`, which the controller forwards to
/// `updateSplitFractions:`. The authoritative shares come back as a
/// `splitVisualsChanged:` notification and are re-applied via
/// `update(layout:fractions:)`.
///
/// A pane dragged to another slot takes its share along, where Chromium
/// keeps shares with their slots: once the reorder has landed, the host
/// commits the reordered shares the same way and ignores the old order's
/// echoes meanwhile (`landPaneMove`).
///
/// Panes are addressed by slot: 0 is the left column of a vertical split and
/// the top row of a horizontal one. Mapping a slot back to a tab id is the
/// controller's job.
final class SplitPaneHostView: NSView {

    /// Also mirrored by `SplitTabDropContainer.paneRects` so the pane-mode
    /// drop hint cards line up with the real panes — keep that in mind when
    /// changing the value.
    static let dividerThickness: CGFloat = 4
    /// Default inset between the split host's bounds and the rounded pane
    /// cards. Comfortable and Balanced omit it at the top so split content
    /// matches the normal WebContent distance below the address bar.
    static let paneInset: CGFloat = 4
    /// Width of the focused pane's ring, drawn just inside the pane card's
    /// edge. A page overlay covering one pane (Reader View) insets by it so
    /// the ring stays visible around the overlay.
    static let focusRingThickness: CGFloat = 2
    /// The least share of the split axis any pane keeps while dragging.
    static let minPaneFraction: CGFloat = 0.1
    /// How long the panes take to move for a preview. The drop hint cards
    /// move in step with them.
    static let panePreviewAnimationDuration: CFTimeInterval = 0.20
    /// How long a dropped change may take to arrive before the panes go back,
    /// in case Chromium declines it.
    private static let panePreviewHoldTimeout: TimeInterval = 2
    /// How far a pane's handle moves before the press becomes a drag.
    private static let paneMoveDragThreshold: CGFloat = 4
    /// How far off the split axis a dragged pane goes to leave the split, at
    /// most: a short pane needs only a third of its length.
    private static let panePullOutDistance: CGFloat = 120
    /// How far past the host a dragged pane goes to leave the split, so a
    /// drag along the top edge can stray above it.
    private static let panePullOutMargin: CGFloat = 40
    /// A pane leaving the split shrinks to this share of its size.
    private static let panePullOutScale: CGFloat = 0.5
    /// How far a divider's grab area reaches into the pane on each side of
    /// it. The divider itself is too thin to hit reliably.
    static let dividerGrabOutset: CGFloat = 3
    /// How long shares that differ from the ones a pane move committed are
    /// ignored: Chromium keeps shares with their slots, so the first echoes
    /// after a reorder still carry the old order.
    private static let moveFractionsEchoTimeout: TimeInterval = 2
    /// How far two shares may differ and still count as the same.
    private static let fractionMatchTolerance: CGFloat = 0.005

    /// Ratios the divider magnetically snaps to while dragging, as the first
    /// neighbour's share of the two panes it separates: an even split plus
    /// one-third / two-thirds for the common asymmetric layouts.
    private let magneticSnapRatios: [CGFloat] = [1.0 / 3.0, 0.5, 2.0 / 3.0]
    /// How close (in points) the divider must come to a snap ratio before it
    /// sticks. Converted to a ratio per-drag from the usable axis length.
    private let magneticSnapDistance: CGFloat = 18

    private(set) var paneLayout: SplitLayout
    /// Each pane's share of the split axis in slot order, summing to 1.
    private(set) var fractions: [CGFloat]
    private(set) var layoutMode: LayoutMode

    /// Per-pane state. The container hosts the Chromium native view and
    /// (optionally) a docked DevTools view scoped to just that pane. Layout
    /// positions the containers — the native views and DevTools views
    /// auto-fill (or take a manual frame when DevTools is shrinking the
    /// inspected page). Overlays are quick-lookup mirrors; the container owns
    /// the strong references via the view hierarchy. They must be kept across
    /// `attach()` (see its keep set).
    private final class PaneSlot {
        let container = NSView()
        weak var native: NSView?
        weak var devToolsView: NSView?
        /// Renderer crash view overlaying a pane whose tab's renderer crashed.
        /// It sits above (and hides) the dead Chromium native view.
        weak var crashView: NSView?
        /// Login-required presentation for account-backed content in a Guest
        /// NTP. Kept separate from crash overlays so a renderer crash can
        /// still take visual priority when both states are briefly present.
        weak var loginRequiredView: NSView?
        /// Yellow screen-share frame shown while the pane's tab is mirrored.
        /// Lives in the host above the focus ring, not in the container.
        let mirroredBorderOverlay = ScreenShareMirroredBorderOverlayView()
    }

    private var slots: [PaneSlot] = []
    /// One divider between each neighbouring pair of panes.
    private var dividers: [DividerHandle] = []
    private let focusRingView: FocusRingView

    /// The pane cards' native views in slot order (nil where a pane has
    /// none yet).
    var panes: [NSView?] { slots.map { $0.native } }
    var paneCount: Int { slots.count }

    /// Which pane currently owns the active tab. Drives the accent-colored
    /// focus ring drawn on top of the pane. Nil hides the ring.
    var focusedPane: Int? {
        didSet {
            guard oldValue != focusedPane else { return }
            needsLayout = true
        }
    }

    /// See `WebContentViewController.hasContentSurface`. The host's own fill
    /// shows only around the pane cards but lies under them too, so over a
    /// content surface it moves to `gapFillView`, which leaves them out.
    var hasContentSurface = false {
        didSet {
            guard hasContentSurface != oldValue else { return }
            applyFills()
            needsLayout = true
        }
    }

    /// The host's fill with the pane cards cut out of it, present only over a
    /// content surface and laid out with the panes.
    private var gapFillView: NSView?

    /// Fires when the user releases a divider with new pane shares.
    var onFractionsCommit: (([Double]) -> Void)?

    /// Fires when the user drops a pane on another slot, with both slots.
    var onPaneMove: ((_ from: Int, _ to: Int) -> Void)?

    /// Fires when the user drags the pane at this slot out of the split.
    var onPaneRemove: ((Int) -> Void)?

    /// Where the pane at this slot goes when it is dragged out and released,
    /// in this view's coordinates: its row in the sidebar. The pane flies as
    /// far toward it as the page area reaches. Nil shrinks it where it is.
    var paneExitTarget: ((Int) -> CGRect?)?

    /// Fires when a preview held for a dropped change ends: the change
    /// arrived, or never did and the hold timed out.
    var onPreviewHoldEnded: (() -> Void)?

    /// Asked while a pane is dragged off the page. Returns true when a tab
    /// drag has taken over from this one, which ends it here.
    var onPaneDragOffPage: ((_ slot: Int, _ event: NSEvent) -> Bool)?

    /// Whether panes show a handle to drag them to another slot.
    var allowsPaneMove = true {
        didSet {
            guard allowsPaneMove != oldValue else { return }
            updateMoveHandleVisibility()
        }
    }

    var hidesTopMoveHandle = false {
        didSet {
            if hidesTopMoveHandle != oldValue { updateMoveHandleVisibility() }
        }
    }

    private func updateMoveHandleVisibility() {
        for (slot, handle) in moveHandles.enumerated() {
            handle.isHidden = !allowsPaneMove || (hidesTopMoveHandle && paneLayout == .horizontal && slot == 0)
        }
    }

    /// Fires on a user click inside one of the panes (not a divider), with
    /// the pane's slot. The owning controller uses this to make the
    /// corresponding tab active so clicking an unfocused pane focuses it —
    /// same as native browsers.
    var onPaneInteraction: ((Int) -> Void)?

    /// A change being previewed: the panes lay out as if it had happened.
    private enum PanePreview: Equatable {
        /// A dragged tab would join at `slot`, leaving its space open.
        case insertion(slot: Int)
        /// The pane at `from` would move to `to`.
        case move(from: Int, to: Int)
        /// The pane at `slot` would leave the split, the others filling in.
        case removal(slot: Int)
        /// The pane at `slot` was released outside the split and shrinks
        /// away to `target` before it is removed. The others fill in at
        /// their new size; the last one left takes the whole host, as it
        /// will once the split is gone.
        case exit(slot: Int, target: CGRect)
    }

    /// A reorder dropped and not yet echoed back: the slot each place takes
    /// its pane from, and the shares once every pane keeps its own.
    private struct PendingMove {
        let order: [Int]
        let fractions: [CGFloat]
    }

    /// Shares this host committed and waits to see echoed.
    private struct ExpectedFractions {
        let fractions: [CGFloat]
        let deadline: CFTimeInterval
        /// The latest shares ignored meanwhile, applied if the wait runs out.
        var deferred: [CGFloat]?
    }

    private struct PaneAnimation {
        let timer: Timer
        let startTime: CFTimeInterval
        let panes: [CGRect]
        let dividers: [CGRect]
        let completion: (() -> Void)?
    }

    private struct PaneMoveDrag {
        let slot: Int
        let startPoint: NSPoint
        let startFrame: CGRect
        var isActive = false
        /// Distance dragged along the split axis.
        var translation: CGFloat = 0
        /// Where the pointer is now.
        var point: NSPoint = .zero
    }

    private var panePreview: PanePreview?
    private var paneAnimation: PaneAnimation?
    private var paneMoveDrag: PaneMoveDrag?
    /// True from the drop until the change arrives, so the panes stay put
    /// instead of going back and moving again.
    private var isHoldingPanePreview = false
    private var panePreviewHoldGeneration = 0
    /// One handle per pane, for dragging it to another slot.
    private var moveHandles: [PaneMoveHandle] = []
    /// Each pane child's autoresizing mask, saved while the preview pins it.
    private var pinnedPaneChildren: [(view: NSView, mask: NSView.AutoresizingMask)] = []
    private var pendingMove: PendingMove?
    private var expectedFractions: ExpectedFractions?
    private var expectedFractionsGeneration = 0
    /// The dividers' own rects. Their views are wider (`dividerGrabOutset`).
    private var dividerRects: [CGRect] = []

    /// True on a host that previews a split about to be created
    /// (`beginCreationPreview(page:)`): slot 0 holds the page, slot 1 nothing.
    private(set) var isCreationPreview = false
    /// Where the page sits in a creation preview; nil is the whole host.
    private var creationPageRect: CGRect?
    private lazy var creationPlaceholder = NSView()

    /// True while a dropped change is awaited (see `onPreviewHoldEnded`).
    var isHoldingPreview: Bool { isHoldingPanePreview }

    private var isUserDragging = false
    private var draggingDividerIndex: Int?
    private var dragStartLocation: NSPoint = .zero
    /// The two shares the dragged divider redistributes, captured at
    /// mouse-down.
    private var dragStartFractions: (leading: CGFloat, trailing: CGFloat) = (0, 0)
    /// Snap ratio the divider is currently stuck to, or nil when free. Tracked
    /// so the alignment haptic fires once on entry, not every mouse move.
    private var activeMagneticSnap: CGFloat?
    /// False until the dragged divider has left the snap point it started
    /// on. A divider that starts on one would otherwise stay stuck to it for
    /// the first `magneticSnapDistance` points and seem not to move.
    private var isMagneticSnapArmed = false
    private var paneClickMonitor: Any?
    /// The pane a left or middle click went down on, by its native view so a
    /// pane reorder or replacement during the click can't misdirect it.
    private weak var pendingInteractionPane: NSView?

    /// Pane attachment is deliberately deferred: the caller must mount the
    /// host in its target hostView (so `self` has a window) **before** calling
    /// `update(panes:)`. Reparenting a Chromium native view into a windowless
    /// host takes it briefly out of any window, and `RenderWidgetHostViewCocoa`
    /// tears down its compositor / IOSurface layer in that interval — it does
    /// not always cleanly resume on the subsequent non-nil transition, which
    /// manifests as every split pane going blank.
    init(layout: SplitLayout, fractions: [Double], layoutMode: LayoutMode) {
        self.paneLayout = layout
        self.fractions = Self.normalized(fractions.map { CGFloat($0) }, count: max(2, fractions.count))
        self.layoutMode = layoutMode
        self.focusRingView = FocusRingView()
        super.init(frame: .zero)
        wantsLayer = true
        applyFills()
        // The ring goes in first: pane containers and dividers are inserted
        // below it as they are created.
        addSubview(focusRingView)
        focusRingView.isHidden = true
        ensureSlotCount(self.fractions.count)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        if let paneClickMonitor {
            NSEvent.removeMonitor(paneClickMonitor)
        }
    }

    /// The shell window moves by its background, and a press that just
    /// misses a divider lands here, on the gap around the panes: it must not
    /// drag the window away while the pointer still shows a resize cursor.
    override var mouseDownCanMoveWindow: Bool { false }

    /// Install the click monitor only when actually mounted in a window. Two
    /// split hosts can coexist in the same window (one per WebContentVC), but
    /// only the topmost one receives clicks — the hit-test filter inside the
    /// monitor body ensures dormant hosts stay silent.
    override func viewDidMoveToWindow() {
        if window == nil {
            endPanePreview()
        }
        super.viewDidMoveToWindow()
        if window == nil {
            removePaneClickMonitor()
        } else if paneClickMonitor == nil {
            installPaneClickMonitor()
        }
    }

    private func installPaneClickMonitor() {
        paneClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .otherMouseUp]
        ) { [weak self] event in
            switch event.type {
            case .leftMouseUp, .otherMouseUp:
                self?.handleGlobalMouseUp(event)
            default:
                self?.handleGlobalMouseDown(event)
            }
            return event
        }
    }

    private func removePaneClickMonitor() {
        if let paneClickMonitor {
            NSEvent.removeMonitor(paneClickMonitor)
            self.paneClickMonitor = nil
        }
        pendingInteractionPane = nil
    }

    /// Activating a pane's tab mid-click swaps the split host and moves the
    /// pane views, which drops the click: a link clicked in an unfocused pane
    /// would only focus it. So a left or middle click focuses its pane once
    /// the mouse-up has reached the page. A right click focuses right away —
    /// its context menu swallows the mouse-up.
    private func handleGlobalMouseUp(_ event: NSEvent) {
        guard let pane = pendingInteractionPane, event.window === window else { return }
        pendingInteractionPane = nil
        DispatchQueue.main.async { [weak self, weak pane] in
            guard let self, self.window != nil, let pane,
                  let slot = self.slots.firstIndex(where: { $0.native === pane }) else { return }
            self.onPaneInteraction?(slot)
        }
    }

    private func handleGlobalMouseDown(_ event: NSEvent) {
        pendingInteractionPane = nil
        guard let window, event.window === window else { return }
        // Only act when this host actually receives the click — if another
        // host (or any sibling view) sits above us, hitTest will return
        // something outside our hierarchy and we bail out.
        guard let hitView = window.contentView?.hitTest(event.locationInWindow),
              hitView.isDescendant(of: self) else { return }
        // Ignore divider grabs — those start a resize, not a focus change.
        guard !dividers.contains(where: { hitView.isDescendant(of: $0) }) else { return }
        // Containers (not the raw native views) are the authoritative pane
        // boundary so clicks land on the correct pane even when DevTools is
        // docked alongside the shrunken Chromium view.
        if let slot = slots.firstIndex(where: { hitView.isDescendant(of: $0.container) }) {
            if event.type == .rightMouseDown || slots[slot].native == nil {
                onPaneInteraction?(slot)
            } else {
                pendingInteractionPane = slots[slot].native
            }
        }
    }

    // MARK: - Slots

    /// Creates or retires pane containers and dividers so there are `count`
    /// panes. A retired pane's container is removed with whatever it holds;
    /// the controller moves a surviving native view out first.
    private func ensureSlotCount(_ count: Int) {
        let count = max(2, min(count, SplitGroup.maxPaneCount))
        while slots.count < count {
            let slot = PaneSlot()
            configurePaneContainer(slot.container)
            addSubview(slot.container, positioned: .below, relativeTo: focusRingView)
            slot.mirroredBorderOverlay.isHidden = true
            addSubview(slot.mirroredBorderOverlay, positioned: .above, relativeTo: focusRingView)
            slots.append(slot)
        }
        while slots.count > count {
            let slot = slots.removeLast()
            slot.container.removeFromSuperview()
            slot.mirroredBorderOverlay.removeFromSuperview()
        }
        while dividers.count < count - 1 {
            let index = dividers.count
            let divider = DividerHandle()
            divider.onDragBegan = { [weak self] event in self?.beginDrag(dividerIndex: index, at: event) }
            divider.onDragChanged = { [weak self] event in self?.continueDrag(at: event) }
            divider.onDragEnded = { [weak self] in self?.endDrag() }
            addSubview(divider, positioned: .below, relativeTo: focusRingView)
            dividers.append(divider)
        }
        while dividers.count > count - 1 {
            dividers.removeLast().removeFromSuperview()
        }
        while moveHandles.count < count {
            let index = moveHandles.count
            let handle = PaneMoveHandle()
            handle.onDragBegan = { [weak self] event in self?.beginPaneMove(slot: index, at: event) }
            handle.onDragChanged = { [weak self] event in self?.continuePaneMove(at: event) }
            handle.onDragEnded = { [weak self] in self?.endPaneMove() }
            moveHandles.append(handle)
        }
        while moveHandles.count > count {
            moveHandles.removeLast().removeFromSuperview()
        }
        updateMoveHandleVisibility()
        raiseDividersAndHandles()
        if fractions.count != count {
            fractions = Self.normalized(fractions, count: count)
            expectedFractions = nil
        }
        if let focusedPane, focusedPane >= count {
            self.focusedPane = nil
        }
        applyDividerCursor()
        needsLayout = true
    }

    /// Puts the dividers and move handles back above every pane card, one
    /// just added or just dragged included: a divider's grab area reaches
    /// over the cards beside it.
    private func raiseDividersAndHandles() {
        for divider in dividers {
            addSubview(divider, positioned: .below, relativeTo: focusRingView)
        }
        for handle in moveHandles {
            addSubview(handle, positioned: .below, relativeTo: focusRingView)
        }
    }

    /// Swap in new native views, one per slot. Used after
    /// `splitContentsChanged:` arrives and when the pane count changes.
    /// Also re-attaches when the pane identity is unchanged but a sibling
    /// SplitPaneHostView has stolen the view in the meantime — `native` is a
    /// weak ref to the NSView, so the identity check alone can't tell "still
    /// mine" from "moved away under a still-valid pointer". Check the actual
    /// superview as the source of truth.
    func update(panes: [NSView]) {
        guard panes.count >= 2 else { return }
        var needsReattach = panes.count != slots.count
        if !needsReattach {
            for (slot, pane) in zip(slots, panes)
            where slot.native !== pane || pane.superview !== slot.container {
                needsReattach = true
                break
            }
        }
        if needsReattach {
            if let moved = landedMoveFractions(for: panes) {
                landPaneMove(panes: panes, fractions: moved)
            } else {
                endPanePreview()
                attach(panes: panes)
            }
            needsLayout = true
        }
    }

    /// The shares to lay `panes` out with when they are the reorder this
    /// host previewed and dropped, nil for any other change.
    private func landedMoveFractions(for panes: [NSView]) -> [CGFloat]? {
        guard let pending = pendingMove,
              panes.count == slots.count, pending.order.count == slots.count else { return nil }
        for (place, slot) in pending.order.enumerated() where slots[slot].native !== panes[place] {
            return nil
        }
        return pending.fractions
    }

    /// Takes the reordered panes in where the preview left them. Each pane
    /// keeps its own share, so every card is already the size of the page
    /// moving into it and no page resizes. The cards take their new places
    /// while their pages are still pinned, then the pages move across.
    private func landPaneMove(panes: [NSView], fractions moved: [CGFloat]) {
        let wasHolding = isHoldingPanePreview
        isHoldingPanePreview = false
        panePreviewHoldGeneration += 1
        paneMoveDrag = nil
        pendingMove = nil
        stopPaneAnimation()
        panePreview = nil
        fractions = moved
        applyPaneFrames(targetPaneRects())
        attach(panes: panes)
        unpinPaneChildren()
        raiseDividersAndHandles()
        expectFractions(moved)
        // Chromium still holds the shares in their old order. Sent on the
        // next turn: its echo must not land inside the content update that
        // brought the reorder here, which goes on to push the stale shares.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.fractions == moved else { return }
            self.onFractionsCommit?(moved.map { Double($0) })
        }
        if wasHolding {
            onPreviewHoldEnded?()
        }
    }

    /// Ignores incoming shares other than `fractions` for a while
    /// (`moveFractionsEchoTimeout`).
    private func expectFractions(_ fractions: [CGFloat]) {
        expectedFractionsGeneration += 1
        let generation = expectedFractionsGeneration
        expectedFractions = ExpectedFractions(
            fractions: fractions,
            deadline: CACurrentMediaTime() + Self.moveFractionsEchoTimeout,
            deferred: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.moveFractionsEchoTimeout) { [weak self] in
            guard let self, self.expectedFractionsGeneration == generation,
                  let expected = self.expectedFractions else { return }
            // Chromium never took the shares: fall back to what it holds.
            self.expectedFractions = nil
            guard !self.isUserDragging, let deferred = expected.deferred,
                  deferred.count == self.slots.count, deferred != self.fractions else { return }
            self.fractions = deferred
            self.needsLayout = true
        }
    }

    private static func fractionsMatch(_ lhs: [CGFloat], _ rhs: [CGFloat]) -> Bool {
        lhs.count == rhs.count
            && zip(lhs, rhs).allSatisfy { abs($0 - $1) <= fractionMatchTolerance }
    }

    /// Apply incoming server-side layout/shares. Ignored while the user is
    /// actively dragging — local drag wins until release, then Chromium's
    /// echoed value reconciles. Shares that do not match the pane count are
    /// spread evenly until the next echo.
    func update(layout: SplitLayout, fractions: [Double], layoutMode: LayoutMode) {
        guard !isUserDragging else { return }
        var changed = false
        if self.paneLayout != layout {
            self.paneLayout = layout
            updateMoveHandleVisibility()
            applyDividerCursor()
            changed = true
        }
        var normalized = Self.normalized(fractions.map { CGFloat($0) }, count: slots.count)
        if var expected = expectedFractions {
            if Self.fractionsMatch(normalized, expected.fractions)
                || CACurrentMediaTime() >= expected.deadline {
                expectedFractions = nil
            } else {
                // Shares in the order the panes had before a move.
                expected.deferred = normalized
                expectedFractions = expected
                normalized = self.fractions
            }
        }
        if normalized != self.fractions {
            self.fractions = normalized
            changed = true
        }
        if self.layoutMode != layoutMode {
            self.layoutMode = layoutMode
            changed = true
        }
        if changed { needsLayout = true }
    }

    func update(layoutMode: LayoutMode) {
        guard self.layoutMode != layoutMode else { return }
        self.layoutMode = layoutMode
        needsLayout = true
    }

    // MARK: - Attachment

    /// Skips the explicit `removeFromSuperview()` step on purpose: AppKit's
    /// `addSubview(_:positioned:relativeTo:)` atomically moves a view across
    /// superviews, and when both old and new superviews share the same window
    /// it does not emit `viewWillMoveToWindow(nil)`. An explicit
    /// `removeFromSuperview` would defeat that, briefly taking the Chromium
    /// native view out of any window and tripping the compositor teardown
    /// described on `init(layout:fractions:)`.
    ///
    /// Per-pane DevTools state is preserved across reattach: if the pane
    /// already has a DevTools view in its container, the native view is left
    /// in manual-frame mode so the next `updateInspectedPageBounds(slot:…)`
    /// call sizes it correctly. Otherwise the native view is autoresized to
    /// fill the pane container.
    private func attach(panes: [NSView]) {
        // The host must be in-window before panes are attached. A windowless
        // host triggers a viewWillMoveToWindow(nil) on the Chromium native
        // view during the reparent, which tears down the renderer compositor
        // and blanks the pane. The mount paths in `installSplitContent`
        // already guarantee this; the precondition just prevents future
        // callers from quietly violating the invariant.
        precondition(window != nil, "SplitPaneHostView must be in a window before attach(panes:)")
        // A pane that is retiring (the count shrank) may still hold a native
        // view that moves to another slot: park every incoming view in the
        // host first so removing a retired container never takes one out of
        // the window.
        if panes.count < slots.count {
            for pane in panes where pane.superview !== self {
                addSubview(pane, positioned: .below, relativeTo: focusRingView)
            }
        }
        ensureSlotCount(panes.count)
        // Every pane moves to its slot before any slot is swept below: a
        // reordered pane still waiting in its old slot would be swept out of
        // the window and brought back.
        for (slot, pane) in zip(slots, panes) where pane.superview !== slot.container {
            slot.container.addSubview(pane)
        }
        for (slot, pane) in zip(slots, panes) {
            // A pane replace (drag-to-replace) swaps one pane's native view
            // for another tab's while this host stays mounted. The evicted
            // tab's view would otherwise stay behind in its container,
            // stacked under the incoming view and still painting — the "two
            // pages in one pane" artifact. Evict anything that isn't the
            // current pane or a kept overlay; the evicted tab is a background
            // tab now, so tearing its view out of the window here is the
            // normal hidden-tab state and the regular mount path revives it
            // on focus. A reorder is unaffected: the moved view is already
            // re-homed by the addSubview moves, so it never matches.
            let keep: [NSView?] = [pane, slot.devToolsView, slot.crashView, slot.loginRequiredView]
            for stale in slot.container.subviews where !keep.contains(where: { $0 === stale }) {
                stale.removeFromSuperview()
            }
            pane.translatesAutoresizingMaskIntoConstraints = true
            if slot.devToolsView == nil {
                pane.autoresizingMask = [.width, .height]
                pane.frame = slot.container.bounds
            } else {
                pane.autoresizingMask = []
            }
            // Re-raise presentation overlays above the just-re-added native.
            if let loginView = slot.loginRequiredView {
                slot.container.addSubview(loginView, positioned: .above, relativeTo: pane)
            }
            // Renderer crashes take priority over the login-required
            // presentation. attach() re-adds the native via addSubview (on
            // top), which would otherwise bury a kept crash overlay — the
            // dead native then intercepts the overlay's button clicks while
            // drawing nothing (so it still shows).
            if let crashView = slot.crashView {
                slot.container.addSubview(crashView,
                                          positioned: .above,
                                          relativeTo: slot.loginRequiredView ?? pane)
            }
            slot.native = pane
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        // An animation places the panes on its own steps.
        guard paneAnimation == nil else { return }
        applyPaneFrames(targetPaneRects())
    }

    /// Where the panes belong now, with any preview applied.
    private func targetPaneRects() -> (panes: [CGRect], dividers: [CGRect]) {
        if isCreationPreview {
            return ([creationPageRect ?? bounds, .zero], [.zero])
        }
        let total = Self.paneLayoutRect(in: bounds, layoutMode: layoutMode)
        switch panePreview {
        case .insertion(let slot):
            let preview = Self.insertionPreviewRects(in: total,
                                                     layout: paneLayout,
                                                     fractions: fractions,
                                                     slot: slot)
            return (preview.panes, preview.dividers)
        case .move(let from, let to):
            // Every pane keeps its own share and takes it along, so no page
            // changes size, during the drag or after the drop.
            let order = Self.moveOrder(count: fractions.count, from: from, to: to)
            let rects = Self.paneRects(in: total, layout: paneLayout,
                                       fractions: order.map { fractions[$0] })
            var panes = Array(repeating: CGRect.zero, count: fractions.count)
            for (place, pane) in order.enumerated() {
                panes[pane] = rects.panes[place]
            }
            // The dragged pane follows the pointer instead of its slot.
            if let drag = paneMoveDrag, drag.isActive, panes.indices.contains(from) {
                var dragged = panes[from]
                switch paneLayout {
                case .vertical:
                    dragged.origin.x = max(total.minX, min(drag.startFrame.minX + drag.translation,
                                                           total.maxX - dragged.width))
                case .horizontal:
                    dragged.origin.y = max(total.minY, min(drag.startFrame.minY + drag.translation,
                                                           total.maxY - dragged.height))
                }
                panes[from] = dragged
            }
            return (panes, rects.dividers)
        case .removal(let slot):
            var rects = Self.removalPreviewRects(in: total,
                                                 layout: paneLayout,
                                                 fractions: fractions,
                                                 slot: slot)
            if rects.panes.indices.contains(slot) {
                rects.panes[slot] = paneMoveDrag.map { pulledOutFrame(for: $0, in: total) }
                    ?? slots[slot].container.frame
            }
            return rects
        case .exit(let slot, let target):
            var rects = Self.removalPreviewRects(in: total,
                                                 layout: paneLayout,
                                                 fractions: fractions,
                                                 slot: slot)
            // The last pane left fills the host as the unsplit page will,
            // so nothing moves when the split goes.
            if slots.count == 2, rects.panes.indices.contains(1 - slot) {
                rects.panes[1 - slot] = bounds
            }
            if rects.panes.indices.contains(slot) {
                rects.panes[slot] = target
            }
            return rects
        case nil:
            return Self.paneRects(in: total, layout: paneLayout, fractions: fractions)
        }
    }

    private func applyPaneFrames(_ rects: (panes: [CGRect], dividers: [CGRect])) {
        for (handle, rect) in zip(moveHandles, rects.panes) {
            handle.frame = PaneMoveHandle.band(in: rect)
        }
        for (slot, rect) in zip(slots, rects.panes) {
            slot.container.frame = rect
        }
        dividerRects = rects.dividers
        for (divider, rect) in zip(dividers, rects.dividers) {
            divider.frame = Self.dividerGrabFrame(for: rect, layout: paneLayout)
        }
        positionFocusRing(paneFrames: rects.panes)
        positionMirroredBorderOverlays(paneFrames: rects.panes)
        if let gapFillView {
            layoutGapFill(gapFillView)
        }
        clipCoveredPaneCards()
    }

    /// The frame of a divider's view: its rect widened along the split axis
    /// so a press just beside the gap still grabs it.
    static func dividerGrabFrame(for rect: CGRect, layout: SplitLayout) -> CGRect {
        guard !rect.isEmpty else { return rect }
        switch layout {
        case .vertical:
            return rect.insetBy(dx: -dividerGrabOutset, dy: 0)
        case .horizontal:
            return rect.insetBy(dx: 0, dy: -dividerGrabOutset)
        }
    }

    /// Cuts out of each pane card the part a card above it covers. Over a
    /// content surface the pages draw beneath the whole view tree and the
    /// cards are clear, so the border of a card under the dragged pane would
    /// otherwise show through the dragged page.
    private func clipCoveredPaneCards() {
        let cards = hasContentSurface
            ? slots.map(\.container).filter { !$0.isHidden && !$0.frame.isEmpty }
            : []
        var stacking: [ObjectIdentifier: Int] = [:]
        if cards.count > 1 {
            for (index, view) in subviews.enumerated() {
                stacking[ObjectIdentifier(view)] = index
            }
        }
        for slot in slots {
            let card = slot.container
            guard let layer = card.layer else { continue }
            let level = stacking[ObjectIdentifier(card)] ?? 0
            let covering = cards.filter {
                $0 !== card
                    && (stacking[ObjectIdentifier($0)] ?? 0) > level
                    && $0.frame.intersects(card.frame)
            }
            guard !covering.isEmpty, !card.isHidden, !card.frame.isEmpty else {
                if layer.mask != nil {
                    layer.mask = nil
                }
                continue
            }
            let holes = covering.map { cover -> CGPath in
                let hole = cover.frame.offsetBy(dx: -card.frame.minX, dy: -card.frame.minY)
                let radius = min(outerCornerRadius, hole.width / 2, hole.height / 2)
                return CGPath(roundedRect: hole, cornerWidth: radius, cornerHeight: radius, transform: nil)
            }
            // United first, as in `layoutGapFill`: the mask is even-odd.
            let path = CGMutablePath()
            path.addRect(card.bounds)
            if let first = holes.first {
                path.addPath(holes.dropFirst().reduce(first) { $0.union($1) })
            }
            let mask = layer.mask as? CAShapeLayer ?? CAShapeLayer()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.fillRule = .evenOdd
            mask.frame = card.bounds
            mask.path = path
            if layer.mask !== mask {
                layer.mask = mask
            }
            CATransaction.commit()
        }
    }

    /// Pane and divider rectangles for `fractions` inside `total` (already
    /// inset by `paneLayoutRect`). Shared with the drop container's pane
    /// mode so its hint cards line up with the real panes. The vertical
    /// layout lays columns out left to right; the horizontal one lays rows
    /// out top to bottom (slot 0 on top, matching Chromium's "position 0"
    /// semantic for visual stacking) with integral heights: CALayer's
    /// autoresizing rounds fractional resize deltas to whole points, and
    /// repeatedly alternating a Chromium pane between integral and
    /// fractional heights accumulates that rounding in its flipped display
    /// layer.
    static func paneRects(in total: CGRect,
                          layout: SplitLayout,
                          fractions: [CGFloat]) -> (panes: [CGRect], dividers: [CGRect]) {
        let count = fractions.count
        guard count >= 1 else { return ([], []) }
        let dividerCount = CGFloat(max(0, count - 1))
        var panes: [CGRect] = []
        var dividers: [CGRect] = []
        switch layout {
        case .vertical:
            let available = max(0, total.width - dividerThickness * dividerCount)
            var x = total.minX
            for (index, fraction) in fractions.enumerated() {
                let width = index == count - 1
                    ? max(0, total.maxX - x)
                    : max(0, available * fraction)
                panes.append(CGRect(x: x, y: total.minY, width: width, height: total.height))
                x += width
                if index < count - 1 {
                    dividers.append(CGRect(x: x, y: total.minY,
                                           width: dividerThickness, height: total.height))
                    x += dividerThickness
                }
            }
        case .horizontal:
            let available = max(0, total.height - dividerThickness * dividerCount)
            // y=0 is bottom in AppKit; walk down from the top.
            var top = total.maxY
            for (index, fraction) in fractions.enumerated() {
                let height = index == count - 1
                    ? max(0, top - total.minY)
                    : max(0, (available * fraction).rounded())
                panes.append(CGRect(x: total.minX, y: top - height,
                                    width: total.width, height: height))
                top -= height
                if index < count - 1 {
                    dividers.append(CGRect(x: total.minX, y: top - dividerThickness,
                                           width: total.width, height: dividerThickness))
                    top -= dividerThickness
                }
            }
        }
        return (panes, dividers)
    }

    /// Where the panes sit once a pane joins at `slot`, and the space it
    /// takes. Mirrors Chromium's `SplitTabVisualData::InsertPane`, so the
    /// preview matches where the panes land: the new pane gets an equal share
    /// and the others shrink in proportion. `dividers` leaves out the one
    /// next to the opened space.
    static func insertionPreviewRects(in total: CGRect,
                                      layout: SplitLayout,
                                      fractions: [CGFloat],
                                      slot: Int) -> (panes: [CGRect], dividers: [CGRect], opened: CGRect) {
        let insertAt = max(0, min(slot, fractions.count))
        let share = 1 / CGFloat(fractions.count + 1)
        var withNewPane = fractions.map { $0 * (1 - share) }
        withNewPane.insert(share, at: insertAt)
        var rects = paneRects(in: total, layout: layout, fractions: withNewPane)
        let opened = rects.panes.remove(at: insertAt)
        if !rects.dividers.isEmpty {
            rects.dividers.remove(at: min(insertAt, rects.dividers.count - 1))
        }
        return (rects.panes, rects.dividers, opened)
    }

    // MARK: - Pane previews

    /// Opens the space for a pane a dragged tab would join at `slot`, or
    /// closes it when nil. The panes' pages are cropped rather than resized
    /// so hovering never reflows them; they take their new size on the drop.
    func setInsertionPreview(slot: Int?) {
        guard !isHoldingPanePreview else { return }
        applyPanePreview(slot.map { .insertion(slot: $0) })
    }

    /// Keeps the space for `slot` open until the dropped pane arrives.
    func holdInsertionPreview(slot: Int) {
        isHoldingPanePreview = true
        applyPanePreview(.insertion(slot: slot))
        schedulePanePreviewRelease()
    }

    /// Closes a held preview if the change it waits for never arrives.
    private func schedulePanePreviewRelease() {
        panePreviewHoldGeneration += 1
        let generation = panePreviewHoldGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.panePreviewHoldTimeout) { [weak self] in
            guard let self, self.panePreviewHoldGeneration == generation,
                  self.isHoldingPanePreview else { return }
            self.isHoldingPanePreview = false
            self.pendingMove = nil
            // A creation preview's owner closes it and takes the host down.
            if !self.isCreationPreview {
                self.applyPanePreview(nil)
            }
            self.onPreviewHoldEnded?()
        }
    }

    /// Drops any preview without animating, leaving the next layout to place
    /// the panes.
    private func endPanePreview() {
        let wasHolding = isHoldingPanePreview
        isHoldingPanePreview = false
        panePreviewHoldGeneration += 1
        paneMoveDrag = nil
        pendingMove = nil
        stopPaneAnimation()
        if panePreview != nil || !pinnedPaneChildren.isEmpty {
            panePreview = nil
            unpinPaneChildren()
            needsLayout = true
        }
        syncPaneBorders(animated: false)
        if wasHolding {
            onPreviewHoldEnded?()
        }
    }

    private func applyPanePreview(_ preview: PanePreview?) {
        guard preview != panePreview else { return }
        if preview != nil {
            pinPaneChildren()
        }
        panePreview = preview
        syncPaneBorders(animated: true)
        animatePaneFrames(completion: preview == nil ? { [weak self] in self?.unpinPaneChildren() } : nil)
    }

    /// A pane that fills the host on its own shows no card border: the last
    /// pane left as the other exits, and the page of a creation preview
    /// before it makes way. Every other pane shows one.
    private func syncPaneBorders(animated: Bool) {
        for (index, slot) in slots.enumerated() {
            guard let layer = slot.container.layer else { continue }
            var fillsHost = false
            if isCreationPreview {
                fillsHost = index == 0 && creationPageRect == nil
            } else if case .exit(let leaving, _) = panePreview {
                fillsHost = slots.count == 2 && index != leaving
            }
            let width: CGFloat = fillsHost ? 0 : 1
            guard layer.borderWidth != width else { continue }
            if animated, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let fade = CABasicAnimation(keyPath: "borderWidth")
                fade.fromValue = layer.presentation()?.borderWidth ?? layer.borderWidth
                fade.toValue = width
                fade.duration = Self.panePreviewAnimationDuration
                layer.add(fade, forKey: "splitPane.borderWidth")
            } else {
                layer.removeAnimation(forKey: "splitPane.borderWidth")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.borderWidth = width
            CATransaction.commit()
        }
    }

    // MARK: - Creation preview

    /// Where the page and the pane joining it sit in the pair a drop is about
    /// to create: an even split of `bounds`, as Chromium creates it.
    static func creationPreviewRects(in bounds: CGRect,
                                     layoutMode: LayoutMode,
                                     layout: SplitLayout,
                                     newPaneIsPrimary: Bool) -> (page: CGRect, opened: CGRect) {
        let total = paneLayoutRect(in: bounds, layoutMode: layoutMode)
        let panes = paneRects(in: total, layout: layout, fractions: [0.5, 0.5]).panes
        return newPaneIsPrimary ? (panes[1], panes[0]) : (panes[0], panes[1])
    }

    /// Turns this host into the preview of a split a dragged tab would form
    /// with `page`: the page alone, filling the host as it does unsplit,
    /// until `setCreationPreview(page:)` moves it aside. The host must be in
    /// its window at its final size. The page is cropped rather than resized
    /// while it makes way, as panes are for `setInsertionPreview(slot:)`.
    func beginCreationPreview(page: NSView) {
        isCreationPreview = true
        creationPageRect = nil
        allowsPaneMove = false
        focusedPane = nil
        ensureSlotCount(2)
        slots[1].container.isHidden = true
        dividers.forEach { $0.isHidden = true }
        syncPaneBorders(animated: false)
        applyPaneFrames(targetPaneRects())
        attach(panes: [page, creationPlaceholder])
    }

    /// Moves the page of a creation preview to `page`, or back over the
    /// whole host when nil. `completion` runs once it is there, unless
    /// another move replaces this one first.
    func setCreationPreview(page: CGRect?, animated: Bool = true, completion: (() -> Void)? = nil) {
        guard isCreationPreview, !isHoldingPanePreview else { return }
        guard page != creationPageRect else {
            if paneAnimation == nil {
                completion?()
            }
            return
        }
        if page != nil {
            pinPaneChildren()
        }
        creationPageRect = page
        syncPaneBorders(animated: animated)
        let finish: () -> Void = { [weak self] in
            if page == nil {
                self?.unpinPaneChildren()
            }
            completion?()
        }
        if animated {
            animatePaneFrames(completion: finish)
        } else {
            stopPaneAnimation()
            applyPaneFrames(targetPaneRects())
            finish()
        }
    }

    /// Keeps the page of a creation preview aside until the split a drop
    /// asked for arrives. The owner takes this host down when it does, or
    /// when `onPreviewHoldEnded` reports it never did.
    func holdCreationPreview() {
        guard isCreationPreview, creationPageRect != nil else { return }
        isHoldingPanePreview = true
        schedulePanePreviewRelease()
    }

    /// Pins each pane's content at its current size against the pane's top
    /// left, so a narrower pane crops its page.
    private func pinPaneChildren() {
        guard pinnedPaneChildren.isEmpty else { return }
        for slot in slots {
            for child in slot.container.subviews {
                pinnedPaneChildren.append((child, child.autoresizingMask))
                child.autoresizingMask = [.maxXMargin, .minYMargin]
            }
        }
    }

    /// Lets the pinned pane content follow its pane again. `keptSlot` names a
    /// pane whose content stays pinned.
    private func unpinPaneChildren(exceptSlot keptSlot: Int? = nil) {
        let keptContainer = keptSlot.flatMap { slot($0) }?.container
        var stillPinned: [(view: NSView, mask: NSView.AutoresizingMask)] = []
        for (child, mask) in pinnedPaneChildren {
            if let keptContainer, child.superview === keptContainer {
                stillPinned.append((child, mask))
                continue
            }
            child.autoresizingMask = mask
            // Manually framed children (DevTools) have no flexible size and
            // get their frame from the controller.
            if mask.contains(.width), mask.contains(.height), let container = child.superview {
                child.frame = container.bounds
            }
        }
        pinnedPaneChildren = stillPinned
    }

    // MARK: - Pane animation

    /// Moves the panes to their current target, starting from where they are
    /// so a drag can change the target mid-move. Frames change on every step
    /// rather than through Core Animation: a page drawn through the content
    /// surface follows its view's frame and never sees a layer's animation.
    private func animatePaneFrames(completion: (() -> Void)? = nil) {
        stopPaneAnimation()
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            applyPaneFrames(targetPaneRects())
            completion?()
            return
        }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stepPaneAnimation()
            }
        }
        paneAnimation = PaneAnimation(timer: timer,
                                      startTime: CACurrentMediaTime(),
                                      panes: slots.map { $0.container.frame },
                                      dividers: dividerRects.count == dividers.count
                                          ? dividerRects
                                          : dividers.map { $0.frame },
                                      completion: completion)
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stepPaneAnimation() {
        guard let animation = paneAnimation else { return }
        let elapsed = CACurrentMediaTime() - animation.startTime
        let progress = CGFloat(min(1, elapsed / Self.panePreviewAnimationDuration))
        let target = targetPaneRects()
        guard progress < 1 else {
            stopPaneAnimation()
            applyPaneFrames(target)
            animation.completion?()
            return
        }
        let eased = progress * progress * (3 - 2 * progress)
        applyPaneFrames((zip(animation.panes, target.panes).map { Self.interpolate($0, $1, eased) },
                         zip(animation.dividers, target.dividers).map { Self.interpolate($0, $1, eased) }))
    }

    private func stopPaneAnimation() {
        paneAnimation?.timer.invalidate()
        paneAnimation = nil
    }

    private static func interpolate(_ start: CGRect, _ end: CGRect, _ progress: CGFloat) -> CGRect {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + (b - a) * progress).rounded() }
        return CGRect(x: mix(start.minX, end.minX),
                      y: mix(start.minY, end.minY),
                      width: mix(start.width, end.width),
                      height: mix(start.height, end.height))
    }

    // MARK: - Dragging a pane

    private func beginPaneMove(slot: Int, at event: NSEvent) {
        guard allowsPaneMove, panePreview == nil, !isHoldingPanePreview, slot < slots.count else { return }
        paneMoveDrag = PaneMoveDrag(slot: slot,
                                    startPoint: convert(event.locationInWindow, from: nil),
                                    startFrame: slots[slot].container.frame)
    }

    private func continuePaneMove(at event: NSEvent) {
        guard var drag = paneMoveDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !drag.isActive {
            guard hypot(point.x - drag.startPoint.x, point.y - drag.startPoint.y) >= Self.paneMoveDragThreshold else {
                return
            }
            drag.isActive = true
            pinPaneChildren()
            // Stacking follows view order, on the content surface too.
            addSubview(slots[drag.slot].container, positioned: .below, relativeTo: focusRingView)
            raiseDividersAndHandles()
        }
        drag.translation = paneLayout == .vertical
            ? point.x - drag.startPoint.x
            : point.y - drag.startPoint.y
        drag.point = point
        paneMoveDrag = drag

        if !bounds.contains(point), onPaneDragOffPage?(drag.slot, event) == true {
            paneMoveDrag = nil
            moveHandles.forEach { $0.hideGrip() }
            isHoldingPanePreview = true
            schedulePanePreviewRelease()
            panePreview = .removal(slot: drag.slot)
            animatePaneFrames()
            return
        }

        let preview: PanePreview = isPulledOut(drag)
            ? .removal(slot: drag.slot)
            : .move(from: drag.slot, to: slot(nearest: point))
        if preview != panePreview {
            panePreview = preview
            animatePaneFrames()
        } else if paneAnimation == nil {
            applyPaneFrames(targetPaneRects())
        }
    }

    /// Lets the pane settle into its new place before reordering, so the
    /// page swap lands on panes that are already there.
    private func endPaneMove() {
        guard let drag = paneMoveDrag else { return }
        paneMoveDrag = nil
        guard drag.isActive else { return }
        switch panePreview {
        case .move(let from, let to) where from != to:
            isHoldingPanePreview = true
            let order = Self.moveOrder(count: fractions.count, from: from, to: to)
            pendingMove = PendingMove(order: order, fractions: order.map { fractions[$0] })
            animatePaneFrames { [weak self] in
                guard let self else { return }
                self.schedulePanePreviewRelease()
                self.onPaneMove?(from, to)
            }
        case .removal(let slot):
            exitPane(slot: slot, toward: paneExitTarget?(slot))
        default:
            panePreview = nil
            animatePaneFrames { [weak self] in self?.unpinPaneChildren() }
        }
    }

    /// Sends the released pane off toward `target`, its row in the sidebar,
    /// and asks for its removal once it is there. A page cannot draw outside
    /// the page area, so the pane stops at the host's edge nearest the row.
    /// The panes that stay take their new size now rather than when the
    /// removal lands, the last one left over the whole host.
    private func exitPane(slot: Int, toward target: CGRect?) {
        guard slots.indices.contains(slot) else { return }
        isHoldingPanePreview = true
        let frame = slots[slot].container.frame
        var exitRect = CGRect(x: frame.midX, y: frame.midY, width: 0, height: 0)
        if let target, !target.isEmpty {
            exitRect.size = CGSize(width: min(target.width, frame.width, bounds.width),
                                   height: min(target.height, frame.height, bounds.height))
            exitRect.origin.x = max(bounds.minX, min(target.minX, bounds.maxX - exitRect.width))
            exitRect.origin.y = max(bounds.minY, min(target.minY, bounds.maxY - exitRect.height))
        }
        panePreview = .exit(slot: slot, target: exitRect)
        unpinPaneChildren(exceptSlot: slot)
        syncPaneBorders(animated: true)
        animatePaneFrames { [weak self] in
            guard let self else { return }
            self.schedulePanePreviewRelease()
            self.onPaneRemove?(slot)
        }
    }

    /// Whether the drag has gone far enough off the split to leave it.
    private func isPulledOut(_ drag: PaneMoveDrag) -> Bool {
        let margin = Self.panePullOutMargin
        guard bounds.insetBy(dx: -margin, dy: -margin).contains(drag.point) else { return true }
        let (offAxis, length) = paneLayout == .vertical
            ? (abs(drag.point.y - drag.startPoint.y), drag.startFrame.height)
            : (abs(drag.point.x - drag.startPoint.x), drag.startFrame.width)
        return offAxis >= min(Self.panePullOutDistance, length / 3)
    }

    /// A shrunken pane hanging from the pointer by its top edge, kept inside
    /// `total` where the page card would cut it off.
    private func pulledOutFrame(for drag: PaneMoveDrag, in total: CGRect) -> CGRect {
        let width = drag.startFrame.width * Self.panePullOutScale
        let height = drag.startFrame.height * Self.panePullOutScale
        return CGRect(x: max(total.minX, min(drag.point.x - width / 2, total.maxX - width)),
                      y: max(total.minY, min(drag.point.y - height, total.maxY - height)),
                      width: width,
                      height: height)
    }

    /// The pane slot along the split axis nearest `point`, ignoring any
    /// preview so the answer does not shift as panes move.
    private func slot(nearest point: NSPoint) -> Int {
        let total = Self.paneLayoutRect(in: bounds, layoutMode: layoutMode)
        let panes = Self.paneRects(in: total, layout: paneLayout, fractions: fractions).panes
        func distance(to pane: CGRect) -> CGFloat {
            let (low, high, value) = paneLayout == .vertical
                ? (pane.minX, pane.maxX, point.x)
                : (pane.minY, pane.maxY, point.y)
            return value < low ? low - value : value > high ? value - high : 0
        }
        return panes.indices.min { distance(to: panes[$0]) < distance(to: panes[$1]) } ?? 0
    }

    /// Where the other panes sit once the pane at `slot` leaves, in current
    /// slot order. Mirrors Chromium's `SplitTabVisualData::RemovePane`: they
    /// keep their proportions. The leaving pane's rect is left empty for the
    /// caller, and the divider it frees is empty too.
    static func removalPreviewRects(in total: CGRect,
                                    layout: SplitLayout,
                                    fractions: [CGFloat],
                                    slot: Int) -> (panes: [CGRect], dividers: [CGRect]) {
        guard fractions.indices.contains(slot), fractions.count > 1 else {
            return paneRects(in: total, layout: layout, fractions: fractions)
        }
        var remaining = fractions
        remaining.remove(at: slot)
        let sum = remaining.reduce(0, +)
        let shares = sum > 0 ? remaining.map { $0 / sum } : remaining.map { _ in 1 / CGFloat(remaining.count) }
        var rects = paneRects(in: total, layout: layout, fractions: shares)
        rects.panes.insert(.zero, at: slot)
        rects.dividers.append(.zero)
        return rects
    }

    /// The current slot each place holds once the pane at `from` moves to
    /// `to`, in place order. A pane takes its share along, so laying the
    /// shares out in this order gives the split after the move.
    static func moveOrder(count: Int, from: Int, to: Int) -> [Int] {
        var order = Array(0..<max(0, count))
        guard order.indices.contains(from), order.indices.contains(to) else { return order }
        order.remove(at: from)
        order.insert(from, at: to)
        return order
    }

    /// The host's and pane cards' fills (see `hasContentSurface`).
    private func applyFills() {
        setFill(ThemedColor.extensionSurfaceBackground.cgColorMapperOptional,
                overContentSurface: hasContentSurface)
        for slot in slots {
            slot.container.setFill(NSColor.white <> NSColor.black,
                                   overContentSurface: hasContentSurface)
        }
        gapFillView?.removeFromSuperview()
        gapFillView = nil
        guard hasContentSurface else { return }
        let gapFill = GapFillView()
        gapFill.wantsLayer = true
        gapFill.phiLayer?.setBackgroundColor(.extensionSurfaceBackground)
        let mask = CAShapeLayer()
        mask.fillRule = .evenOdd
        gapFill.layer?.mask = mask
        addSubview(gapFill, positioned: .below, relativeTo: nil)
        gapFillView = gapFill
    }

    private func layoutGapFill(_ gapFillView: NSView) {
        gapFillView.frame = bounds
        guard let mask = gapFillView.layer?.mask as? CAShapeLayer else { return }
        // Circular corners, as Chromium rounds the panes' pixels; the cards'
        // own continuous curve has no CGPath form.
        let cards = slots.filter { !$0.container.isHidden }
            .map { $0.container.frame }.filter { !$0.isEmpty }.map { card -> CGPath in
            let radius = min(outerCornerRadius, card.width / 2, card.height / 2)
            return CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        // United first: the mask is even-odd, so cards that overlap while one
        // is dragged would otherwise fill in where they cross.
        let path = CGMutablePath()
        path.addRect(bounds)
        if let first = cards.first {
            path.addPath(cards.dropFirst().reduce(first) { $0.union($1) })
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = gapFillView.bounds
        mask.path = path
        CATransaction.commit()
    }

    /// Shared pane-card area used by both the real split host and its pane
    /// drop hints. Modes with a top address bar align split and single content
    /// at the same header boundary; Performance preserves the legacy inset.
    static func paneLayoutRect(in bounds: CGRect, layoutMode: LayoutMode) -> CGRect {
        let topInset: CGFloat
        switch layoutMode {
        case .comfortable, .balanced:
            topInset = 0
        case .performance:
            topInset = paneInset
        }
        return CGRect(
            x: bounds.minX + paneInset,
            y: bounds.minY + paneInset,
            width: max(0, bounds.width - paneInset * 2),
            height: max(0, bounds.height - paneInset - topInset)
        )
    }

    /// Per-pane rounded card. `masksToBounds` clips DevTools and the Chromium
    /// native view to the corner radius so each pane reads as a standalone
    /// card rather than as parts of one outer clip.
    private func configurePaneContainer(_ container: NSView) {
        container.wantsLayer = true
        container.layer?.cornerCurve = .continuous
        container.layer?.cornerRadius = outerCornerRadius
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.phiLayer?.setBorderColor(.border)
        container.setFill(NSColor.white <> NSColor.black,
                          overContentSurface: hasContentSurface)
    }

    /// Outer corner radius the focus ring should follow at the pane corners
    /// that meet the rounded bottom of `leftContainerView` in
    /// `WebContentViewController`. Matches the inner-components radius so the
    /// stroke traces the parent clip instead of being chopped off square.
    var squaresCorners = false {
        didSet {
            guard squaresCorners != oldValue else { return }
            for slot in slots {
                slot.container.layer?.cornerRadius = outerCornerRadius
            }
            needsLayout = true
        }
    }

    private var outerCornerRadius: CGFloat {
        squaresCorners ? 0 : LiquidGlassCompatible.webContentInnerComponentsCornerRadius
    }

    private func slot(_ index: Int) -> PaneSlot? {
        guard index >= 0, index < slots.count else { return nil }
        return slots[index]
    }

    // MARK: - DevTools (per-pane)

    /// Mount a docked DevTools view into the given pane's container. The
    /// pane's native Chromium view is switched to manual-frame mode so the
    /// next `updateInspectedPageBounds(slot:…)` call can shrink it to the
    /// area DevTools JS reports. Idempotent: re-calling with the same view
    /// is a no-op; a different view replaces any previous one.
    func attachDevTools(slot index: Int, devToolsView: NSView) {
        guard let slot = slot(index), let native = slot.native else { return }
        let container = slot.container
        if slot.devToolsView === devToolsView, devToolsView.superview === container {
            return
        }
        if let stale = slot.devToolsView, stale !== devToolsView {
            stale.removeFromSuperview()
        }
        devToolsView.wantsLayer = true
        // DevTools sits behind the Chromium native view so the inspected
        // page renders on top within whatever subrect the bounds callback
        // gives us (matches the non-split path in `WebContentViewController`).
        container.addSubview(devToolsView, positioned: .below, relativeTo: native)
        devToolsView.frame = container.bounds
        devToolsView.autoresizingMask = [.width, .height]
        // Switch the Chromium native view to manual frame so the next bounds
        // callback can shrink it without AppKit's autoresize fighting back.
        native.autoresizingMask = []
        native.translatesAutoresizingMaskIntoConstraints = true
        native.frame = container.bounds
        slot.devToolsView = devToolsView
    }

    /// Tear down DevTools for the given pane and restore the native view to
    /// autoresized fill. Safe to call when no DevTools is attached.
    func detachDevTools(slot index: Int) {
        guard let slot = slot(index) else { return }
        slot.devToolsView?.removeFromSuperview()
        slot.devToolsView = nil
        if let native = slot.native, native.superview === slot.container {
            native.translatesAutoresizingMaskIntoConstraints = true
            native.autoresizingMask = [.width, .height]
            native.frame = slot.container.bounds
            native.isHidden = false
        }
    }

    /// Apply DevTools-reported page bounds to the pane's Chromium native
    /// view. `bounds` is in web coordinates (origin top-left) and relative to
    /// the pane container, matching how DevTools JS computes the inspected
    /// area inside its own host frame.
    func updateInspectedPageBounds(slot index: Int, bounds inspected: CGRect, hide: Bool) {
        guard let slot = slot(index), let native = slot.native,
              native.superview === slot.container else { return }
        if hide {
            native.isHidden = true
            return
        }
        native.isHidden = false
        let containerHeight = slot.container.bounds.height
        let flippedY = containerHeight - inspected.origin.y - inspected.size.height
        native.frame = NSRect(x: inspected.origin.x, y: flippedY,
                              width: inspected.size.width, height: inspected.size.height)
    }

    /// True if DevTools is currently docked to the given pane's container.
    func hasDevTools(slot index: Int) -> Bool {
        slot(index)?.devToolsView != nil
    }

    /// The pane's rounded card — what a page overlay scoped to one pane
    /// (Reader View) covers. Its frame follows divider drags.
    func paneCardView(slot index: Int) -> NSView? {
        slot(index)?.container
    }

    // MARK: - Crash view (per-pane)

    /// Overlay an opaque crash view on the given pane, covering its dead
    /// Chromium native view. The native view is left untouched (not hidden, not
    /// reframed, not reparented) — the overlay just sits above and fills the
    /// pane. Must be in the `attach()` keep set or a re-layout evicts it.
    func attachCrashView(slot index: Int, crashView: NSView) {
        guard let slot = slot(index) else { return }
        let container = slot.container
        if slot.crashView === crashView, crashView.superview === container {
            return
        }
        if let stale = slot.crashView, stale !== crashView {
            stale.removeFromSuperview()
        }
        crashView.wantsLayer = true
        container.addSubview(crashView,
                             positioned: .above,
                             relativeTo: slot.loginRequiredView ?? slot.native)
        crashView.frame = container.bounds
        crashView.autoresizingMask = [.width, .height]
        slot.crashView = crashView
    }

    /// Remove the crash overlay from the given pane. The native view was never
    /// hidden or reframed, so there is nothing to restore — just drop the
    /// overlay. Safe to call when no crash view is attached.
    func detachCrashView(slot index: Int) {
        guard let slot = slot(index) else { return }
        slot.crashView?.removeFromSuperview()
        slot.crashView = nil
    }

    /// True if a crash view is currently overlaying the given pane.
    func hasCrashView(slot index: Int) -> Bool {
        slot(index)?.crashView != nil
    }

    /// The crash view currently overlaying the given pane, if any. Lets the
    /// controller identity-check that a pane shows the expected tab's crash
    /// view before skipping a rebuild (guards against crossed panes).
    func crashView(slot index: Int) -> NSView? {
        slot(index)?.crashView
    }

    // MARK: - Login Required (per-pane)

    func attachLoginRequiredView(slot index: Int, loginRequiredView: NSView) {
        guard let slot = slot(index) else { return }
        let container = slot.container
        if slot.loginRequiredView === loginRequiredView, loginRequiredView.superview === container {
            return
        }
        if let stale = slot.loginRequiredView, stale !== loginRequiredView {
            stale.removeFromSuperview()
        }
        loginRequiredView.wantsLayer = true
        container.addSubview(loginRequiredView, positioned: .above, relativeTo: slot.native)
        loginRequiredView.frame = container.bounds
        loginRequiredView.autoresizingMask = [.width, .height]
        slot.loginRequiredView = loginRequiredView

        if let crashView = slot.crashView {
            container.addSubview(crashView, positioned: .above, relativeTo: loginRequiredView)
        }
    }

    func detachLoginRequiredView(slot index: Int) {
        guard let slot = slot(index) else { return }
        slot.loginRequiredView?.removeFromSuperview()
        slot.loginRequiredView = nil
    }

    /// Detaches every per-pane overlay of the given kind; used when the
    /// controller stops presenting a state across the whole split.
    func detachAllLoginRequiredViews() {
        for index in slots.indices {
            detachLoginRequiredView(slot: index)
        }
    }

    private func positionFocusRing(paneFrames: [NSRect]) {
        // A ring on another pane would draw across the pane being dragged,
        // and one around a pane that is leaving or taking over the host
        // would vanish with the split.
        var isExiting = false
        if case .exit = panePreview {
            isExiting = true
        }
        guard paneMoveDrag?.isActive != true, !isExiting,
              let focusedPane, focusedPane < paneFrames.count else {
            focusRingView.isHidden = true
            return
        }
        focusRingView.isHidden = false
        focusRingView.frame = paneFrames[focusedPane]
        focusRingView.updatePath(outerRadius: outerCornerRadius)
    }

    /// Yellow screen-share frame for a mirrored pane (#259).
    func setMirroredBorderVisible(_ visible: Bool, slot index: Int) {
        slot(index)?.mirroredBorderOverlay.setActive(visible)
    }

    private func positionMirroredBorderOverlays(paneFrames: [NSRect]) {
        let radius = outerCornerRadius
        for (slot, frame) in zip(slots, paneFrames) {
            slot.mirroredBorderOverlay.frame = frame
            slot.mirroredBorderOverlay.cornerRadius = radius
        }
    }

    // MARK: - Divider dragging

    private func beginDrag(dividerIndex: Int, at event: NSEvent) {
        guard dividerIndex + 1 < fractions.count else { return }
        isUserDragging = true
        draggingDividerIndex = dividerIndex
        dragStartLocation = convert(event.locationInWindow, from: nil)
        dragStartFractions = (fractions[dividerIndex], fractions[dividerIndex + 1])
        activeMagneticSnap = nil
        isMagneticSnapArmed = false
        // The user sets the shares now, whatever a pane move still awaits.
        expectedFractions = nil
    }

    /// Signed drag distance that grows the leading pane when positive.
    /// In a stacked split the leading pane sits above the divider, so dragging
    /// downward grows it even though AppKit's y coordinate decreases.
    static func leadingPaneGrowthDistance(layout: SplitLayout,
                                          from start: CGPoint,
                                          to current: CGPoint) -> CGFloat {
        switch layout {
        case .vertical:
            return current.x - start.x
        case .horizontal:
            return start.y - current.y
        }
    }

    private func continueDrag(at event: NSEvent) {
        guard let index = draggingDividerIndex, index + 1 < fractions.count else { return }
        let location = convert(event.locationInWindow, from: nil)
        let dividerCount = CGFloat(max(0, fractions.count - 1))
        let usable: CGFloat
        switch paneLayout {
        case .vertical:
            usable = bounds.width - Self.dividerThickness * dividerCount
        case .horizontal:
            usable = bounds.height - Self.dividerThickness * dividerCount
        }
        guard usable > 0 else { return }
        // The divider redistributes the two shares it separates; the other
        // panes keep theirs.
        let pairShare = dragStartFractions.leading + dragStartFractions.trailing
        let pairPoints = usable * pairShare
        guard pairPoints > 0 else { return }
        let delta = Self.leadingPaneGrowthDistance(
            layout: paneLayout,
            from: dragStartLocation,
            to: location
        ) / pairPoints
        let rawRatio = dragStartFractions.leading / pairShare + delta
        let minRatio = Self.minPaneFraction / pairShare
        let clampedRatio = max(minRatio, min(1 - minRatio, rawRatio))
        var snapTarget = magneticSnapTarget(for: clampedRatio, usable: pairPoints)
        if !isMagneticSnapArmed {
            // The divider moves freely until it is out of reach of the snap
            // point it started on, if any; after that every point pulls,
            // that one included.
            let startSnap = magneticSnapTarget(for: dragStartFractions.leading / pairShare,
                                               usable: pairPoints)
            if startSnap == nil || snapTarget != startSnap {
                isMagneticSnapArmed = true
            } else {
                snapTarget = nil
            }
        }
        emitSnapFeedbackIfNeeded(snapTarget)
        let ratio = snapTarget.map { max(minRatio, min(1 - minRatio, $0)) } ?? clampedRatio
        let leading = pairShare * ratio
        let trailing = pairShare - leading
        if abs(fractions[index] - leading) > .ulpOfOne {
            fractions[index] = leading
            fractions[index + 1] = trailing
            needsLayout = true
        }
    }

    private func endDrag() {
        isUserDragging = false
        draggingDividerIndex = nil
        activeMagneticSnap = nil
        onFractionsCommit?(fractions.map { Double($0) })
    }

    /// Snap ratio the divider should stick to at `ratio`, or nil when it's
    /// outside every snap point's pull radius. `usable` is the draggable axis
    /// length in points, turning the point threshold into a ratio.
    private func magneticSnapTarget(for ratio: CGFloat, usable: CGFloat) -> CGFloat? {
        guard usable > 0 else { return nil }
        let threshold = magneticSnapDistance / usable
        var target: CGFloat?
        var closest = threshold
        for snap in magneticSnapRatios {
            let distance = abs(ratio - snap)
            if distance < closest {
                closest = distance
                target = snap
            }
        }
        return target
    }

    /// Fire a single alignment haptic when the divider enters a new snap zone,
    /// matching macOS's feel when window edges align.
    private func emitSnapFeedbackIfNeeded(_ target: CGFloat?) {
        guard target != activeMagneticSnap else { return }
        activeMagneticSnap = target
        if target != nil {
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment, performanceTime: .drawCompleted)
        }
    }

    /// One share per pane, summing to 1: `values` when they fit (every value
    /// at least `minPaneFraction`), equal shares otherwise.
    static func normalized(_ values: [CGFloat], count: Int) -> [CGFloat] {
        let count = max(1, count)
        guard values.count == count, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return Array(repeating: 1 / CGFloat(count), count: count)
        }
        let sum = values.reduce(0, +)
        guard sum > 0 else { return Array(repeating: 1 / CGFloat(count), count: count) }
        var result = values.map { $0 / sum }
        // Lift any pane below the floor and take the difference from the
        // largest, so a pane never collapses to nothing.
        let floor = min(minPaneFraction, 1 / CGFloat(count))
        for index in result.indices where result[index] < floor {
            let deficit = floor - result[index]
            result[index] = floor
            if let largest = result.indices.max(by: { result[$0] < result[$1] }), largest != index {
                result[largest] = max(floor, result[largest] - deficit)
            }
        }
        let total = result.reduce(0, +)
        return total > 0 ? result.map { $0 / total } : result
    }

    private func applyDividerCursor() {
        for divider in dividers {
            switch paneLayout {
            case .vertical:   divider.dragCursor = .resizeLeftRight
            case .horizontal: divider.dragCursor = .resizeUpDown
            }
        }
    }
}

/// The host's fill around the pane cards over a content surface. Like the
/// host, it never starts a window drag (`SplitPaneHostView.mouseDownCanMoveWindow`).
private final class GapFillView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Pane move handle

/// The grip along the top of a pane for dragging it to another slot. It
/// appears when the pointer nears the pane's top edge, and only the grip
/// itself takes the mouse, so the rest of the band still reaches the page.
private final class PaneMoveHandle: NSView {
    private static let bandHeight: CGFloat = 44
    private static let gripSize = CGSize(width: 72, height: 18)
    private static let pillSize = CGSize(width: 40, height: 5)

    /// The strip of `pane` this handle covers.
    static func band(in pane: CGRect) -> CGRect {
        let height = min(bandHeight, pane.height)
        return CGRect(x: pane.minX, y: pane.maxY - height, width: pane.width, height: height)
    }

    var onDragBegan: ((NSEvent) -> Void)?
    var onDragChanged: ((NSEvent) -> Void)?
    var onDragEnded: (() -> Void)?

    private let pill = CALayer()
    private var areas: [NSTrackingArea] = []
    private var touchObserver: TouchTapObserver?
    private var touchHideWorkItem: DispatchWorkItem?
    private var isDragging = false

    private var gripRect: CGRect {
        CGRect(x: bounds.midX - Self.gripSize.width / 2,
               y: bounds.maxY - Self.gripSize.height,
               width: Self.gripSize.width,
               height: Self.gripSize.height)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Over any page, so a light fill with a dark edge.
        pill.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        pill.borderColor = NSColor.black.withAlphaComponent(0.3).cgColor
        pill.borderWidth = 0.5
        pill.cornerRadius = Self.pillSize.height / 2
        pill.opacity = 0
        layer?.addSublayer(pill)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("splitPaneMoveHandle")
        setAccessibilityLabel(NSLocalizedString("browser.splitPane.moveHandle",
                                                value: "Move Pane",
                                                comment: "Accessibility label of the grip at the top of a split pane that drags the pane to a new position"))
        // Touch has no hover: show the pill while a finger is on the grip,
        // where a touch-hold-then-move drags the pane.
        touchObserver = TouchTapObserver(
            view: self,
            onTouchBegan: { [weak self] in self?.showGripForTouch() },
            onTap: { _ in }
        )
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHiddenOrHasHiddenAncestor && gripRect.contains(convert(point, from: superview)) ? self : nil
    }

    override func layout() {
        super.layout()
        layoutPill()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutPill()
    }

    private func layoutPill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.frame = CGRect(x: gripRect.midX - Self.pillSize.width / 2,
                            y: gripRect.midY - Self.pillSize.height / 2,
                            width: Self.pillSize.width,
                            height: Self.pillSize.height)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        areas.forEach { removeTrackingArea($0) }
        areas = [
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                           owner: self, userInfo: nil),
            NSTrackingArea(rect: gripRect, options: [.cursorUpdate, .activeInKeyWindow],
                           owner: self, userInfo: nil),
        ]
        areas.forEach { addTrackingArea($0) }
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        pill.opacity = 1
    }

    override func mouseExited(with event: NSEvent) {
        pill.opacity = 0
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        NSCursor.closedHand.set()
        onDragBegan?(event)
    }

    override func mouseDragged(with event: NSEvent) {
        onDragChanged?(event)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        hideGrip()
        onDragEnded?()
    }

    func hideGrip() {
        touchHideWorkItem?.cancel()
        touchHideWorkItem = nil
        pill.opacity = 0
    }

    /// Hides again after a few seconds if the touch does not turn into a drag.
    private func showGripForTouch() {
        pill.opacity = 1
        touchHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isDragging else { return }
            self.hideGrip()
        }
        touchHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }
}

// MARK: - Divider

/// Transparent strip between two pane cards — it's purely a drag/hit area.
/// Whatever sits behind the split host (`leftContainerView`'s fill) shows
/// through, so the gap reads as background rather than as its own chrome
/// strip. The view is wider than the gap by
/// `SplitPaneHostView.dividerGrabOutset` on each side and sits above the
/// cards, so a press just beside the gap still grabs the divider.
private final class DividerHandle: NSView {
    var dragCursor: NSCursor = .resizeLeftRight {
        didSet { resetTrackingArea() }
    }
    var onDragBegan: ((NSEvent) -> Void)?
    var onDragChanged: ((NSEvent) -> Void)?
    var onDragEnded: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The shell window sets `isMovableByWindowBackground`, and AppKit's
    /// default for a non-opaque view lets the window take over the drag
    /// after its first few events, moving the window instead of the divider.
    override var mouseDownCanMoveWindow: Bool { false }

    /// Undocumented AppKit hook: the window server moves the window on its own
    /// for presses in the titlebar strip unless a view claims the rect here,
    /// and AppKit claims nothing for a view that draws nothing. Chromium's
    /// `BridgedContentView` overrides it the same way.
    @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect {
        bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        resetTrackingArea()
    }

    private func resetTrackingArea() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        dragCursor.set()
    }

    override func mouseDown(with event: NSEvent) {
        onDragBegan?(event)
    }

    override func mouseDragged(with event: NSEvent) {
        onDragChanged?(event)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}

// MARK: - Focus ring

/// 2pt border overlaid on the focused pane. Painted in the active browser
/// theme color so the focused pane reads with the same affordance as other
/// themed chrome. Hit-test transparent so clicks pass through to Chromium
/// content and still fire `onPaneInteraction`.
///
/// Uses `CALayer.cornerCurve = .continuous` so the rounded corners exactly
/// match the pane container's squircle clip.
private final class FocusRingView: NSView {
    private let borderThickness = SplitPaneHostView.focusRingThickness
    private var themeObservation: AnyObject?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = borderThickness
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 0
        applyBorderColor()
        themeObservation = subscribe { [weak self] _, _ in
            self?.applyBorderColor()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Set the outer corner radius to follow. Panes are standalone rounded
    /// cards on all four corners, so no per-corner masking is needed.
    func updatePath(outerRadius: CGFloat) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = outerRadius
        CATransaction.commit()
    }

    private func applyBorderColor() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.borderColor = ThemedColor.themeColor.resolve(in: self).cgColor
        CATransaction.commit()
    }
}
