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

    private let dividerThickness: CGFloat = 5
    private let minPaneFraction: CGFloat = 0.1

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
        primaryPaneContainer.wantsLayer = true
        secondaryPaneContainer.wantsLayer = true
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
        primaryPane = primary
        secondaryPane = secondary
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let total = bounds
        switch paneLayout {
        case .vertical:
            let primaryWidth = (total.width - dividerThickness) * ratio
            let secondaryWidth = total.width - dividerThickness - primaryWidth
            primaryPaneContainer.frame = NSRect(x: 0, y: 0,
                                                width: primaryWidth, height: total.height)
            dividerView.frame = NSRect(x: primaryWidth, y: 0,
                                       width: dividerThickness, height: total.height)
            secondaryPaneContainer.frame = NSRect(x: primaryWidth + dividerThickness, y: 0,
                                                  width: secondaryWidth, height: total.height)
        case .horizontal:
            let primaryHeight = (total.height - dividerThickness) * ratio
            let secondaryHeight = total.height - dividerThickness - primaryHeight
            // y=0 is bottom in AppKit; primary on top matches Chromium's
            // "position 0" semantic for visual stacking.
            secondaryPaneContainer.frame = NSRect(x: 0, y: 0,
                                                  width: total.width, height: secondaryHeight)
            dividerView.frame = NSRect(x: 0, y: secondaryHeight,
                                       width: total.width, height: dividerThickness)
            primaryPaneContainer.frame = NSRect(x: 0, y: secondaryHeight + dividerThickness,
                                                width: total.width, height: primaryHeight)
        }
        positionFocusRing(primaryFrame: primaryPaneContainer.frame,
                          secondaryFrame: secondaryPaneContainer.frame)
    }

    /// Outer corner radius the focus ring should follow at the pane corners
    /// that meet the rounded bottom of `leftContainerView` in
    /// `WebContentViewController`. Matches the inner-components radius so the
    /// stroke traces the parent clip instead of being chopped off square.
    private var outerCornerRadius: CGFloat {
        LiquidGlassCompatible.webContentInnerComponentsCornerRadius + 4
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

    private func positionFocusRing(primaryFrame: NSRect, secondaryFrame: NSRect) {
        guard let focusedPane else {
            focusRingView.isHidden = true
            return
        }
        focusRingView.isHidden = false
        focusRingView.frame = (focusedPane == .primary) ? primaryFrame : secondaryFrame
        focusRingView.updatePath(roundedCorners: roundedCorners(for: focusedPane),
                                 outerRadius: outerCornerRadius)
    }

    /// Which corners of the focus ring sit on the rounded edge of the
    /// `leftContainerView` (in `WebContentViewController`) and therefore need
    /// to be drawn as arcs instead of square. Divider-side corners are
    /// always square. The bottom is always at the rounded ancestor's bottom
    /// (hostView pins to leftContainerView's bottom); the top is only at the
    /// rounded ancestor's top in sidebar layout, where the URL bar and
    /// bookmark bar collapse to zero height — detected dynamically by
    /// comparing edge positions.
    private func roundedCorners(for pane: Pane) -> FocusRingView.RoundedCorners {
        let topRounded = topEdgeMeetsRoundedAncestor()
        switch paneLayout {
        case .vertical:
            var corners: FocusRingView.RoundedCorners =
                (pane == .primary) ? [.bottomLeft] : [.bottomRight]
            if topRounded {
                corners.insert(pane == .primary ? .topLeft : .topRight)
            }
            return corners
        case .horizontal:
            switch pane {
            case .primary:
                // Top pane: bottom edge meets the divider, top edge may meet
                // the rounded ancestor when the header bar is collapsed.
                return topRounded ? [.topLeft, .topRight] : []
            case .secondary:
                // Bottom pane spans the full width at the rounded bottom.
                return [.bottomLeft, .bottomRight]
            }
        }
    }

    /// True when our top edge coincides with the top edge of the nearest
    /// ancestor that has a non-zero `cornerRadius` — i.e. the rounded
    /// clipper above us also rounds at the top. Returns false if no such
    /// ancestor exists.
    private func topEdgeMeetsRoundedAncestor() -> Bool {
        var ancestor: NSView? = superview
        while let current = ancestor {
            if (current.layer?.cornerRadius ?? 0) > 0 {
                let myTopInAncestor = convert(bounds, to: current).maxY
                return abs(myTopInAncestor - current.bounds.maxY) < 0.5
            }
            ancestor = current.superview
        }
        return false
    }

    // MARK: - Divider dragging

    private func beginDrag(at event: NSEvent) {
        isUserDragging = true
        dragStartLocation = convert(event.locationInWindow, from: nil)
        dragStartRatio = ratio
    }

    private func continueDrag(at event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let newRatio: CGFloat
        switch paneLayout {
        case .vertical:
            let usable = bounds.width - dividerThickness
            guard usable > 0 else { return }
            let delta = (location.x - dragStartLocation.x) / usable
            newRatio = clamp(dragStartRatio + delta)
        case .horizontal:
            let usable = bounds.height - dividerThickness
            guard usable > 0 else { return }
            // y grows upward; primary sits on top, so drag-up = larger primary.
            let delta = (location.y - dragStartLocation.y) / usable
            newRatio = clamp(dragStartRatio + delta)
        }
        if abs(ratio - newRatio) > .ulpOfOne {
            ratio = newRatio
            needsLayout = true
        }
    }

    private func endDrag() {
        isUserDragging = false
        onRatioCommit?(Double(ratio))
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

/// Solid 8pt strip painted in the theme's window-overlay color (tint + alpha
/// — the same tone painted behind the sidebar). Lets the divider read as a
/// strip of the window chrome between two content cards, and lets the
/// custom theme show through instead of a white slab. Width is also the
/// drag hit area — no separate invisible grab band needed.
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
        phiLayer?.setBackgroundColor(.windowOverlayBackground)
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

/// 3pt border overlaid on the focused pane. Painted in the theme's
/// window-overlay hue blended ~35% toward black (light mode) or white
/// (dark mode) — same color family as the divider but deeper, so it reads
/// clearly against white/dark content while still feeling part of the
/// theme. Hit-test transparent so clicks pass through to Chromium content
/// and still fire `onPaneInteraction`.
///
/// Uses `CALayer.cornerCurve = .continuous` + `maskedCorners` so the
/// rounded corners exactly match `leftContainerView`'s squircle clip in
/// `WebContentViewController`. A plain circular arc would leave a sliver
/// of the border clipped in the squircle-vs-circle transition region,
/// reading as a thinner stroke at the corner than along the straight
/// edges.
private final class FocusRingView: NSView {
    private let borderThickness: CGFloat = 2
    private var themeObservation: AnyObject?

    struct RoundedCorners: OptionSet {
        let rawValue: Int
        static let topLeft     = RoundedCorners(rawValue: 1 << 0)
        static let topRight    = RoundedCorners(rawValue: 1 << 1)
        static let bottomRight = RoundedCorners(rawValue: 1 << 2)
        static let bottomLeft  = RoundedCorners(rawValue: 1 << 3)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = borderThickness
        layer?.cornerCurve = .continuous
        layer?.maskedCorners = []
        layer?.cornerRadius = 0
        applyBorderColor()
        themeObservation = subscribe { [weak self] _, _ in
            self?.applyBorderColor()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Set which corners should curve (matching the parent clip) and the
    /// outer corner radius to follow. Square corners stay sharp because
    /// `maskedCorners` excludes them — `CALayer.borderWidth` follows the
    /// effective shape, so the unmasked corners render as right angles.
    func updatePath(roundedCorners: RoundedCorners, outerRadius: CGFloat) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = outerRadius
        layer.maskedCorners = Self.cornerMask(from: roundedCorners)
        CATransaction.commit()
    }

    private func applyBorderColor() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.borderColor = Self.focusRingColor.resolve(in: self).cgColor
        CATransaction.commit()
    }

    /// Map visual-corner names to `CACornerMask`. For an NSView with
    /// `wantsLayer = true` and the default non-flipped coordinate system,
    /// the backing layer's bounds use y-up — so `minY` corresponds to the
    /// visual bottom and `maxY` to the visual top.
    private static func cornerMask(from corners: RoundedCorners) -> CACornerMask {
        var mask: CACornerMask = []
        if corners.contains(.bottomLeft)  { mask.insert(.layerMinXMinYCorner) }
        if corners.contains(.bottomRight) { mask.insert(.layerMaxXMinYCorner) }
        if corners.contains(.topLeft)     { mask.insert(.layerMinXMaxYCorner) }
        if corners.contains(.topRight)    { mask.insert(.layerMaxXMaxYCorner) }
        return mask
    }

    private static let focusRingColor = ThemedColor { theme, appearance in
        let tint = ThemedColor.windowOverlayBackground
            .resolve(theme: theme, appearance: appearance)
            .withAlphaComponent(1.0)
        let contrast: NSColor = appearance.isDark ? .white : .black
        return tint.blended(withFraction: 0.35, of: contrast) ?? tint
    }
}
