// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Hosts two Chromium native views side-by-side (or stacked) with a draggable
/// divider. Pure view — owns no model state; the owning controller pushes
/// updates in and observes drag-end via `onRatioCommit`.
///
/// Chromium is source of truth for the ratio: every drag-end calls
/// `onRatioCommit`, which the controller forwards to `updateSplitRatio:`.
/// The authoritative new ratio comes back as a `splitVisualsChanged:`
/// notification and is re-applied via `update(layout:ratio:)`.
final class SplitPaneHostView: NSView {

    /// Which side of the split the user interacted with. Mapping back to a
    /// specific tab id is the controller's job — this view only knows about
    /// "primary pane" and "secondary pane" in the split's own coordinates.
    enum Pane {
        case primary
        case secondary
    }

    /// Also mirrored by `SplitTabDropContainer.replacePaneRects` so the
    /// replace-mode drop hint cards line up with the real panes — keep that
    /// in mind when changing the value.
    static let dividerThickness: CGFloat = 4
    /// Inset between the split host's bounds and the rounded pane cards on all
    /// four sides. Lets each pane read as a standalone card floating inside
    /// `leftContainerView`'s clip instead of pinning to its edges.
    static let paneInset: CGFloat = 4
    private let minPaneFraction: CGFloat = 0.1

    /// Ratios the divider magnetically snaps to while dragging: an even split
    /// plus one-third / two-thirds for the common asymmetric layouts.
    private let magneticSnapRatios: [CGFloat] = [1.0 / 3.0, 0.5, 2.0 / 3.0]
    /// How close (in points) the divider must come to a snap ratio before it
    /// sticks. Converted to a ratio per-drag from the usable axis length.
    private let magneticSnapDistance: CGFloat = 18

    private(set) var paneLayout: SplitLayout
    private(set) var ratio: CGFloat

    private let dividerView: DividerHandle
    private let focusRingView: FocusRingView
    /// Per-pane container that hosts the Chromium native view and (optionally)
    /// a docked DevTools view scoped to just that pane. Layout positions these
    /// containers — the native views and DevTools views auto-fill (or take a
    /// manual frame when DevTools is shrinking the inspected page).
    private let primaryPaneContainer = NSView()
    private let secondaryPaneContainer = NSView()
    private(set) weak var primaryPane: NSView?
    private(set) weak var secondaryPane: NSView?
    /// DevTools NSView mounted in the pane's container, when DevTools is
    /// docked to that pane's tab. The container owns the strong reference via
    /// the view hierarchy; this is just a quick-lookup mirror.
    private weak var primaryDevToolsView: NSView?
    private weak var secondaryDevToolsView: NSView?
    /// Renderer crash view overlaying a pane whose tab's renderer crashed. It
    /// sits above (and hides) the dead Chromium native view. Container owns the
    /// strong ref via the view hierarchy; this is a quick-lookup mirror, exactly
    /// like the DevTools views above. Must be kept across `attach()` (see keep).
    private weak var primaryCrashView: NSView?
    private weak var secondaryCrashView: NSView?
    /// Login-required presentation for account-backed content in a Guest NTP.
    /// Kept separate from crash overlays so a renderer crash can still take
    /// visual priority when both states are briefly present.
    private weak var primaryLoginRequiredView: NSView?
    private weak var secondaryLoginRequiredView: NSView?

    /// Which pane currently owns the active tab. Drives the accent-colored
    /// focus ring drawn on top of the pane. Nil hides the ring.
    var focusedPane: Pane? {
        didSet {
            guard oldValue != focusedPane else { return }
            needsLayout = true
        }
    }

    /// Fires when the user releases the divider with a new ratio.
    var onRatioCommit: ((Double) -> Void)?

    /// Fires on any user mouse-down inside one of the panes (not the divider).
    /// The owning controller uses this to make the corresponding tab active so
    /// clicking the unfocused pane focuses it — same as native browsers.
    var onPaneInteraction: ((Pane) -> Void)?

    private var isUserDragging = false
    private var dragStartLocation: NSPoint = .zero
    private var dragStartRatio: CGFloat = 0
    /// Snap ratio the divider is currently stuck to, or nil when free. Tracked
    /// so the alignment haptic fires once on entry, not every mouse move.
    private var activeMagneticSnap: CGFloat?
    private var paneClickMonitor: Any?

    /// Pane attachment is deliberately deferred: the caller must mount the
    /// host in its target hostView (so `self` has a window) **before** calling
    /// `update(primary:secondary:)`. Reparenting a Chromium native view into
    /// a windowless host takes it briefly out of any window, and
    /// `RenderWidgetHostViewCocoa` tears down its compositor / IOSurface layer
    /// in that interval — it does not always cleanly resume on the subsequent
    /// non-nil transition, which manifests as both split panes going blank.
    init(layout: SplitLayout, ratio: Double) {
        self.paneLayout = layout
        self.ratio = CGFloat(ratio)
        self.dividerView = DividerHandle()
        self.focusRingView = FocusRingView()
        super.init(frame: .zero)
        wantsLayer = true
        configurePaneContainer(primaryPaneContainer)
        configurePaneContainer(secondaryPaneContainer)
        addSubview(primaryPaneContainer)
        addSubview(secondaryPaneContainer)
        addSubview(dividerView)
        addSubview(focusRingView, positioned: .above, relativeTo: dividerView)
        focusRingView.isHidden = true
        dividerView.onDragBegan = { [weak self] event in self?.beginDrag(at: event) }
        dividerView.onDragChanged = { [weak self] event in self?.continueDrag(at: event) }
        dividerView.onDragEnded = { [weak self] in self?.endDrag() }
        applyDividerCursor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        if let paneClickMonitor {
            NSEvent.removeMonitor(paneClickMonitor)
        }
    }

    /// Install the click monitor only when actually mounted in a window. Two
    /// split hosts can coexist in the same window (one per WebContentVC), but
    /// only the topmost one receives clicks — the hit-test filter inside the
    /// monitor body ensures dormant hosts stay silent.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removePaneClickMonitor()
        } else if paneClickMonitor == nil {
            installPaneClickMonitor()
        }
    }

    private func installPaneClickMonitor() {
        paneClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.handleGlobalMouseDown(event)
            return event
        }
    }

    private func removePaneClickMonitor() {
        if let paneClickMonitor {
            NSEvent.removeMonitor(paneClickMonitor)
            self.paneClickMonitor = nil
        }
    }

    private func handleGlobalMouseDown(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        // Only act when this host actually receives the click — if another
        // host (or any sibling view) sits above us, hitTest will return
        // something outside our hierarchy and we bail out.
        guard let hitView = window.contentView?.hitTest(event.locationInWindow),
              hitView.isDescendant(of: self) else { return }
        // Ignore divider grabs — those start a resize, not a focus change.
        guard !hitView.isDescendant(of: dividerView) else { return }
        // Containers (not the raw native views) are the authoritative pane
        // boundary so clicks land on the correct pane even when DevTools is
        // docked alongside the shrunken Chromium view.
        if hitView.isDescendant(of: primaryPaneContainer) {
            onPaneInteraction?(.primary)
        } else if hitView.isDescendant(of: secondaryPaneContainer) {
            onPaneInteraction?(.secondary)
        }
    }

    /// Swap in new native views. Used after `splitContentsChanged:` arrives.
    /// Also re-attaches when the pane identity is unchanged but a sibling
    /// SplitPaneHostView has stolen the view in the meantime — `primaryPane`
    /// is a weak ref to the NSView, so the identity check alone can't tell
    /// "still mine" from "moved away under a still-valid pointer". Check the
    /// actual superview as the source of truth.
    func update(primary: NSView, secondary: NSView) {
        let primaryNeedsReattach =
            primaryPane !== primary || primary.superview !== primaryPaneContainer
        let secondaryNeedsReattach =
            secondaryPane !== secondary || secondary.superview !== secondaryPaneContainer
        if primaryNeedsReattach || secondaryNeedsReattach {
            attach(primary: primary, secondary: secondary)
            needsLayout = true
        }
    }

    /// Apply incoming server-side layout/ratio. Ignored while the user is
    /// actively dragging — local drag wins until release, then Chromium's
    /// echoed value reconciles.
    func update(layout: SplitLayout, ratio: Double) {
        guard !isUserDragging else { return }
        var changed = false
        if self.paneLayout != layout {
            self.paneLayout = layout
            applyDividerCursor()
            changed = true
        }
        let clamped = clamp(CGFloat(ratio))
        if abs(self.ratio - clamped) > .ulpOfOne {
            self.ratio = clamped
            changed = true
        }
        if changed { needsLayout = true }
    }

    // MARK: - Attachment

    /// Skips the explicit `removeFromSuperview()` step on purpose: AppKit's
    /// `addSubview(_:positioned:relativeTo:)` atomically moves a view across
    /// superviews, and when both old and new superviews share the same window
    /// it does not emit `viewWillMoveToWindow(nil)`. An explicit
    /// `removeFromSuperview` would defeat that, briefly taking the Chromium
    /// native view out of any window and tripping the compositor teardown
    /// described on `init(layout:ratio:)`.
    ///
    /// Per-pane DevTools state is preserved across reattach: if the pane
    /// already has a DevTools view in its container, the native view is left
    /// in manual-frame mode so the next `updateInspectedPageBounds(pane:…)`
    /// call sizes it correctly. Otherwise the native view is autoresized to
    /// fill the pane container.
    private func attach(primary: NSView, secondary: NSView) {
        // The host must be in-window before panes are attached. A windowless
        // host triggers a viewWillMoveToWindow(nil) on the Chromium native
        // view during the reparent, which tears down the renderer compositor
        // and blanks the pane. The mount paths in `installSplitContent`
        // already guarantee this; the precondition just prevents future
        // callers from quietly violating the invariant.
        precondition(window != nil, "SplitPaneHostView must be in a window before attach(primary:secondary:)")
        if primary.superview !== primaryPaneContainer {
            primaryPaneContainer.addSubview(primary)
        }
        if secondary.superview !== secondaryPaneContainer {
            secondaryPaneContainer.addSubview(secondary)
        }
        // A pane replace (drag-to-replace) swaps one pane's native view for
        // another tab's while this host stays mounted. The evicted tab's
        // view would otherwise stay behind in its container, stacked under
        // the incoming view and still painting — the "two pages in one
        // pane" artifact. Evict anything that isn't the current pair or a
        // docked DevTools view; the evicted tab is a background tab now, so
        // tearing its view out of the window here is the normal hidden-tab
        // state and the regular mount path revives it on focus. Reverse
        // panes is unaffected: the moved view is already re-homed by the
        // addSubview moves above, so it never matches.
        let keep: [NSView?] = [primary, secondary, primaryDevToolsView, secondaryDevToolsView,
                               primaryCrashView, secondaryCrashView,
                               primaryLoginRequiredView, secondaryLoginRequiredView]
        for container in [primaryPaneContainer, secondaryPaneContainer] {
            for stale in container.subviews where !keep.contains(where: { $0 === stale }) {
                stale.removeFromSuperview()
            }
        }
        primary.translatesAutoresizingMaskIntoConstraints = true
        secondary.translatesAutoresizingMaskIntoConstraints = true
        if primaryDevToolsView == nil {
            primary.autoresizingMask = [.width, .height]
            primary.frame = primaryPaneContainer.bounds
        } else {
            primary.autoresizingMask = []
        }
        if secondaryDevToolsView == nil {
            secondary.autoresizingMask = [.width, .height]
            secondary.frame = secondaryPaneContainer.bounds
        } else {
            secondary.autoresizingMask = []
        }
        // Re-raise presentation overlays above the just-re-added native.
        if let loginView = primaryLoginRequiredView {
            primaryPaneContainer.addSubview(loginView, positioned: .above, relativeTo: primary)
        }
        if let loginView = secondaryLoginRequiredView {
            secondaryPaneContainer.addSubview(loginView, positioned: .above, relativeTo: secondary)
        }
        // Renderer crashes take priority over the login-required presentation.
        // attach() re-adds the native via addSubview (on top), which would
        // otherwise bury a kept crash overlay — the dead native then intercepts
        // the overlay's button clicks while drawing nothing (so it still shows).
        if let cv = primaryCrashView {
            primaryPaneContainer.addSubview(
                cv,
                positioned: .above,
                relativeTo: primaryLoginRequiredView ?? primary
            )
        }
        if let cv = secondaryCrashView {
            secondaryPaneContainer.addSubview(
                cv,
                positioned: .above,
                relativeTo: secondaryLoginRequiredView ?? secondary
            )
        }
        primaryPane = primary
        secondaryPane = secondary
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let total = bounds.insetBy(dx: Self.paneInset, dy: Self.paneInset)
        switch paneLayout {
        case .vertical:
            let primaryWidth = (total.width - Self.dividerThickness) * ratio
            let secondaryWidth = total.width - Self.dividerThickness - primaryWidth
            primaryPaneContainer.frame = NSRect(x: total.minX, y: total.minY,
                                                width: primaryWidth, height: total.height)
            dividerView.frame = NSRect(x: total.minX + primaryWidth, y: total.minY,
                                       width: Self.dividerThickness, height: total.height)
            secondaryPaneContainer.frame = NSRect(x: total.minX + primaryWidth + Self.dividerThickness, y: total.minY,
                                                  width: secondaryWidth, height: total.height)
        case .horizontal:
            let availableHeight = total.height - Self.dividerThickness
            // CALayer's width/height autoresizing rounds fractional resize
            // deltas to whole-point changes. Repeatedly alternating a Chromium
            // pane between integral and fractional heights accumulates that
            // rounding in its flipped display layer, so keep the split axis
            // integral at the AppKit boundary. The secondary pane receives the
            // remainder to preserve the exact available height.
            let primaryHeight = (availableHeight * ratio).rounded()
            let secondaryHeight = availableHeight - primaryHeight
            // y=0 is bottom in AppKit; primary on top matches Chromium's
            // "position 0" semantic for visual stacking.
            secondaryPaneContainer.frame = NSRect(x: total.minX, y: total.minY,
                                                  width: total.width, height: secondaryHeight)
            dividerView.frame = NSRect(x: total.minX, y: total.minY + secondaryHeight,
                                       width: total.width, height: Self.dividerThickness)
            primaryPaneContainer.frame = NSRect(x: total.minX, y: total.minY + secondaryHeight + Self.dividerThickness,
                                                width: total.width, height: primaryHeight)
        }
        positionFocusRing(primaryFrame: primaryPaneContainer.frame,
                          secondaryFrame: secondaryPaneContainer.frame)
    }

    /// Per-pane rounded card. `masksToBounds` clips DevTools and the Chromium
    /// native view to the corner radius so each pane reads as a standalone
    /// card rather than as halves of one outer clip.
    private func configurePaneContainer(_ container: NSView) {
        container.wantsLayer = true
        container.layer?.cornerCurve = .continuous
        container.layer?.cornerRadius = outerCornerRadius
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.phiLayer?.setBorderColor(.border)
    }

    /// Outer corner radius the focus ring should follow at the pane corners
    /// that meet the rounded bottom of `leftContainerView` in
    /// `WebContentViewController`. Matches the inner-components radius so the
    /// stroke traces the parent clip instead of being chopped off square.
    private var outerCornerRadius: CGFloat {
        LiquidGlassCompatible.webContentInnerComponentsCornerRadius
    }

    // MARK: - DevTools (per-pane)

    /// Mount a docked DevTools view into the given pane's container. The
    /// pane's native Chromium view is switched to manual-frame mode so the
    /// next `updateInspectedPageBounds(pane:…)` call can shrink it to the
    /// area DevTools JS reports. Idempotent: re-calling with the same view
    /// is a no-op; a different view replaces any previous one.
    func attachDevTools(pane: Pane, devToolsView: NSView) {
        let container = paneContainer(for: pane)
        guard let native = nativePane(for: pane) else { return }
        let existing = existingDevToolsView(for: pane)
        if existing === devToolsView, devToolsView.superview === container {
            return
        }
        if let stale = existing, stale !== devToolsView {
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
        setDevToolsView(devToolsView, for: pane)
    }

    /// Tear down DevTools for the given pane and restore the native view to
    /// autoresized fill. Safe to call when no DevTools is attached.
    func detachDevTools(pane: Pane) {
        let container = paneContainer(for: pane)
        if let dev = existingDevToolsView(for: pane) {
            dev.removeFromSuperview()
        }
        setDevToolsView(nil, for: pane)
        if let native = nativePane(for: pane), native.superview === container {
            native.translatesAutoresizingMaskIntoConstraints = true
            native.autoresizingMask = [.width, .height]
            native.frame = container.bounds
            native.isHidden = false
        }
    }

    /// Apply DevTools-reported page bounds to the pane's Chromium native
    /// view. `bounds` is in web coordinates (origin top-left) and relative to
    /// the pane container, matching how DevTools JS computes the inspected
    /// area inside its own host frame.
    func updateInspectedPageBounds(pane: Pane, bounds inspected: CGRect, hide: Bool) {
        let container = paneContainer(for: pane)
        guard let native = nativePane(for: pane),
              native.superview === container else { return }
        if hide {
            native.isHidden = true
            return
        }
        native.isHidden = false
        let containerHeight = container.bounds.height
        let flippedY = containerHeight - inspected.origin.y - inspected.size.height
        native.frame = NSRect(x: inspected.origin.x, y: flippedY,
                              width: inspected.size.width, height: inspected.size.height)
    }

    /// True if DevTools is currently docked to the given pane's container.
    func hasDevTools(pane: Pane) -> Bool {
        existingDevToolsView(for: pane) != nil
    }

    private func paneContainer(for pane: Pane) -> NSView {
        pane == .primary ? primaryPaneContainer : secondaryPaneContainer
    }

    private func nativePane(for pane: Pane) -> NSView? {
        pane == .primary ? primaryPane : secondaryPane
    }

    private func existingDevToolsView(for pane: Pane) -> NSView? {
        pane == .primary ? primaryDevToolsView : secondaryDevToolsView
    }

    private func setDevToolsView(_ view: NSView?, for pane: Pane) {
        switch pane {
        case .primary: primaryDevToolsView = view
        case .secondary: secondaryDevToolsView = view
        }
    }

    /// Overlay an opaque crash view on the given pane, covering its dead
    /// Chromium native view. The native view is left untouched (not hidden, not
    /// reframed, not reparented) — the overlay just sits above and fills the
    /// pane. Must be in the `attach()` keep set or a re-layout evicts it.
    func attachCrashView(pane: Pane, crashView: NSView) {
        let container = paneContainer(for: pane)
        let existing = existingCrashView(for: pane)
        if existing === crashView, crashView.superview === container {
            return
        }
        if let stale = existing, stale !== crashView {
            stale.removeFromSuperview()
        }
        crashView.wantsLayer = true
        container.addSubview(
            crashView,
            positioned: .above,
            relativeTo: existingLoginRequiredView(for: pane) ?? nativePane(for: pane)
        )
        crashView.frame = container.bounds
        crashView.autoresizingMask = [.width, .height]
        setCrashView(crashView, for: pane)
    }

    /// Remove the crash overlay from the given pane. The native view was never
    /// hidden or reframed, so there is nothing to restore — just drop the
    /// overlay. Safe to call when no crash view is attached.
    func detachCrashView(pane: Pane) {
        existingCrashView(for: pane)?.removeFromSuperview()
        setCrashView(nil, for: pane)
    }

    /// True if a crash view is currently overlaying the given pane.
    func hasCrashView(pane: Pane) -> Bool {
        existingCrashView(for: pane) != nil
    }

    /// The crash view currently overlaying the given pane, if any. Lets the
    /// controller identity-check that a pane shows the expected tab's crash
    /// view before skipping a rebuild (guards against crossed panes).
    func crashView(for pane: Pane) -> NSView? {
        existingCrashView(for: pane)
    }

    private func existingCrashView(for pane: Pane) -> NSView? {
        pane == .primary ? primaryCrashView : secondaryCrashView
    }

    private func setCrashView(_ view: NSView?, for pane: Pane) {
        switch pane {
        case .primary: primaryCrashView = view
        case .secondary: secondaryCrashView = view
        }
    }

    // MARK: - Login Required (per-pane)

    func attachLoginRequiredView(pane: Pane, loginRequiredView: NSView) {
        let container = paneContainer(for: pane)
        let existing = existingLoginRequiredView(for: pane)
        if existing === loginRequiredView, loginRequiredView.superview === container {
            return
        }
        if let stale = existing, stale !== loginRequiredView {
            stale.removeFromSuperview()
        }
        loginRequiredView.wantsLayer = true
        container.addSubview(
            loginRequiredView,
            positioned: .above,
            relativeTo: nativePane(for: pane)
        )
        loginRequiredView.frame = container.bounds
        loginRequiredView.autoresizingMask = [.width, .height]
        setLoginRequiredView(loginRequiredView, for: pane)

        if let crashView = existingCrashView(for: pane) {
            container.addSubview(
                crashView,
                positioned: .above,
                relativeTo: loginRequiredView
            )
        }
    }

    func detachLoginRequiredView(pane: Pane) {
        existingLoginRequiredView(for: pane)?.removeFromSuperview()
        setLoginRequiredView(nil, for: pane)
    }

    private func existingLoginRequiredView(for pane: Pane) -> NSView? {
        pane == .primary ? primaryLoginRequiredView : secondaryLoginRequiredView
    }

    private func setLoginRequiredView(_ view: NSView?, for pane: Pane) {
        switch pane {
        case .primary: primaryLoginRequiredView = view
        case .secondary: secondaryLoginRequiredView = view
        }
    }

    private func positionFocusRing(primaryFrame: NSRect, secondaryFrame: NSRect) {
        guard let focusedPane else {
            focusRingView.isHidden = true
            return
        }
        focusRingView.isHidden = false
        focusRingView.frame = (focusedPane == .primary) ? primaryFrame : secondaryFrame
        focusRingView.updatePath(outerRadius: outerCornerRadius)
    }

    // MARK: - Divider dragging

    private func beginDrag(at event: NSEvent) {
        isUserDragging = true
        dragStartLocation = convert(event.locationInWindow, from: nil)
        dragStartRatio = ratio
        activeMagneticSnap = nil
    }

    /// Signed drag distance that grows the primary pane when positive.
    /// In a stacked split the primary pane sits above the divider, so dragging
    /// downward grows it even though AppKit's y coordinate decreases.
    static func primaryPaneGrowthDistance(layout: SplitLayout,
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
        let location = convert(event.locationInWindow, from: nil)
        let usable: CGFloat
        switch paneLayout {
        case .vertical:
            usable = bounds.width - Self.dividerThickness
        case .horizontal:
            usable = bounds.height - Self.dividerThickness
        }
        guard usable > 0 else { return }
        let delta = Self.primaryPaneGrowthDistance(
            layout: paneLayout,
            from: dragStartLocation,
            to: location
        ) / usable
        let raw = clamp(dragStartRatio + delta)
        let snapTarget = magneticSnapTarget(for: raw, usable: usable)
        emitSnapFeedbackIfNeeded(snapTarget)
        let newRatio = snapTarget ?? raw
        if abs(ratio - newRatio) > .ulpOfOne {
            ratio = newRatio
            needsLayout = true
        }
    }

    private func endDrag() {
        isUserDragging = false
        activeMagneticSnap = nil
        onRatioCommit?(Double(ratio))
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

    private func clamp(_ value: CGFloat) -> CGFloat {
        max(minPaneFraction, min(1 - minPaneFraction, value))
    }

    private func applyDividerCursor() {
        switch paneLayout {
        case .vertical:   dividerView.dragCursor = .resizeLeftRight
        case .horizontal: dividerView.dragCursor = .resizeUpDown
        }
    }
}

// MARK: - Divider

/// Transparent strip between the two pane cards — it's purely a drag/hit
/// area. Whatever sits behind the split host (`leftContainerView`'s fill)
/// shows through, so the gap reads as background rather than as its own
/// chrome strip. Width is also the drag hit area — no separate invisible
/// grab band needed.
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
    private let borderThickness: CGFloat = 2
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

    /// Set the outer corner radius to follow. Panes are now standalone
    /// rounded cards on all four corners, so no per-corner masking is needed.
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
