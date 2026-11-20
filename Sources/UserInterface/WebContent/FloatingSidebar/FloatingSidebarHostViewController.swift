// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit

/// Which way a pin or unpin hands the sidebar between the floating panel
/// and the docked column.
enum SidebarHandOffKind {
    case dock
    case undock
}

/// Owns the hover panel, trigger and dismissal lifetime for one window.
/// Hosted Spaces replace its content; their page trees never own the panel.
final class FloatingSidebarHostViewController: NSViewController {
    private(set) weak var browserState: BrowserState?
    private var subscriptions = Set<AnyCancellable>()
    let floatingSidebarTriggerView = MouseTrackingAreaView()
    private(set) var floatingSidebarContainerView: NSView?
    private(set) var floatingSidebarViewController: FloatingSidebarViewController?
    private var trafficLightStrip: FloatingTrafficLightsView?
    private var sidebarOnRight = false
    private var panelVisualContainer: NSView?
    private var outgoingContent: FloatingSidebarViewController?
    private var panelContentView: NSView?
    private var floatingSidebarLeadingConstraint: Constraint?
    private var floatingSidebarWidthConstraint: Constraint?
    private var floatingSidebarHideWorkItem: DispatchWorkItem?
    private var floatingSidebarEnableWorkItem: DispatchWorkItem?
    private var floatingSidebarWidthSyncWorkItem: DispatchWorkItem?
    private var floatingSidebarLastShownAt: Date?
    /// The pointer has been on the panel or its strip since the panel last
    /// showed. Running on out of the window from there keeps the panel open
    /// (`pointerReachedFloatingSidebar`). Cleared when the panel hides.
    private var pointerTouchedFloatingSidebar = false
    /// The pointer came into the window through the strip and hasn't moved
    /// on into the panel: it is passing by from outside the window, say from
    /// another display, rather than coming from the page.
    private var pointerEnteredWindowThroughStrip = false
    /// The panel is sliding out. Until it is gone, a pointer that would
    /// reveal it brings it back.
    private var isFloatingSidebarHideAnimating = false
    /// Where the pointer is, in window coordinates, for every hover check.
    /// Read at each check; tests replace it.
    lazy var pointerLocationInWindow: () -> NSPoint? = { [weak self] in
        self?.view.window?.mouseLocationOutsideOfEventStream
    }
    private var floatingSidebarOcclusionObserver: NSObjectProtocol?
    private var floatingSidebarGeometryObservers: [NSObjectProtocol] = []
    private var isPointerInsideFloatingSidebar = false
    private var isPointerInsideFloatingSidebarTrigger = false
    /// The strip along the panel's inner edge (the one facing the page)
    /// that resizes it.
    private(set) var floatingSidebarResizeHandle: FloatingSidebarResizeHandleView?
    private var resizeHandleVisibility: AnyCancellable?
    /// The panel stays open while its edge is dragged, wherever the pointer is.
    private(set) var isResizingFloatingSidebar = false
    private var floatingSidebarResizeStartWidth: CGFloat = 0
    private var isSwitchingSpace = false
    private var visibilityGeneration = 0
    /// Popovers shown from inside the panel: the pinned-tab, folder and
    /// Space icon pickers, among others. Each is a window of its own, so
    /// the panel's tracking area loses the pointer once it moves onto one.
    /// While any is up the panel stays pinned open, as for the inline
    /// create-Space form; the last one closing re-runs the hide scheduling.
    private let panelPopovers = NSHashTable<NSPopover>.weakObjects()
    /// Folder and Space previews shown from inside the panel. Each is a
    /// child panel rather than a popover and pins the panel the same way.
    private let panelFolderPreviews = NSHashTable<BookmarkFolderPreview>.weakObjects()
    private var popoverObservers: [NSObjectProtocol] = []
    /// The presented Space's content was made the panel's while the panel
    /// was hidden, without activation or layout; `installContent` runs
    /// before the panel next shows or is realized off screen.
    private var needsContentInstall = false

    /// Whether the right-sidebar layout's top band is revealed. See
    /// `FloatingTrafficLightsView`.
    var isTrafficLightBandVisible: Bool { trafficLightStrip?.isStripVisible == true }

    /// Shows or hides the native lights on the band. The band overlays the
    /// window's content rather than pushing it down, so revealing it never
    /// resizes the page.
    private func trafficLightBandVisibilityChanged(_ visible: Bool) {
        browserState?.windowController?.refreshTrafficLightVisibility()
    }

    var isVisible: Bool { floatingSidebarContainerView?.isHidden == false }

    /// The pointer reached the panel from inside the window, so running on
    /// past the window's edge keeps the panel open.
    var pointerReachedFloatingSidebar: Bool {
        pointerTouchedFloatingSidebar && !pointerEnteredWindowThroughStrip
    }

    /// Up, or on its way up: not hidden, and not sliding out.
    private var isShownOrShowing: Bool { isVisible && !isFloatingSidebarHideAnimating }

    override func loadView() {
        let overlay = FloatingSidebarOverlayView()
        overlay.isOverFullscreenPage = { [weak self] in
            self?.browserState?.focusingTab?.isInContentFullscreen == true
        }
        overlay.onPointerEnteredWindow = { [weak self] event in
            self?.pointerEnteredWindow(at: event.locationInWindow)
        }
        overlay.onPointerLeftWindow = { [weak self] event in
            self?.pointerLeftWindow(at: event.locationInWindow)
        }
        overlay.visiblePanel = { [weak self] in
            guard let self, self.isVisible else { return nil }
            return self.floatingSidebarContainerView
        }
        view = overlay
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        view.layer?.zPosition = WebContentContainerViewController.LayerZIndex.floatingSidebar
        floatingSidebarTriggerView.isHidden = true
        view.addSubview(floatingSidebarTriggerView)
        floatingSidebarTriggerView.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.width.equalTo(Self.floatingSidebarTriggerWidth)
        }
        setupFloatingSidebarTrigger()
        observePanelPopovers()
    }

    /// Tracks popovers and folder previews anchored in the panel (see
    /// `panelPopovers`). The pin starts at will-show, so it also holds while
    /// a popover is still animating open; the anchor is already set by then.
    private func observePanelPopovers() {
        let center = NotificationCenter.default
        popoverObservers.append(center.addObserver(forName: NSPopover.willShowNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let popover = note.object as? NSPopover,
                      self.isAnchoredInPanel(popover) else { return }
                self.panelPopovers.add(popover)
                self.cancelFloatingSidebarHide()
            }
        })
        popoverObservers.append(center.addObserver(forName: NSPopover.didCloseNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let popover = note.object as? NSPopover,
                      self.panelPopovers.contains(popover) else { return }
                self.panelPopovers.remove(popover)
                self.panelOverlayDidClose()
            }
        })
        popoverObservers.append(center.addObserver(forName: .bookmarkFolderPreviewWillShow, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let preview = note.object as? BookmarkFolderPreview,
                      let anchor = preview.anchor, self.isInsideVisiblePanel(anchor) else { return }
                self.panelFolderPreviews.add(preview)
                self.cancelFloatingSidebarHide()
            }
        })
        popoverObservers.append(center.addObserver(forName: .bookmarkFolderPreviewDidClose, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let preview = note.object as? BookmarkFolderPreview,
                      self.panelFolderPreviews.contains(preview) else { return }
                self.panelFolderPreviews.remove(preview)
                self.panelOverlayDidClose()
            }
        })
    }

    private var hasPanelOverlay: Bool {
        !panelPopovers.allObjects.isEmpty || !panelFolderPreviews.allObjects.isEmpty
    }

    private func panelOverlayDidClose() {
        if !hasPanelOverlay, isVisible {
            scheduleFloatingSidebarHide()
        }
    }

    /// Whether `popover` is anchored to a view inside the visible panel.
    /// NSPopover keeps its anchor in `positioningView`, which it doesn't
    /// publish; probed so a future AppKit without it falls back to the
    /// unpinned behavior instead of raising.
    private func isAnchoredInPanel(_ popover: NSPopover) -> Bool {
        guard popover.responds(to: NSSelectorFromString("positioningView")),
              let anchor = popover.value(forKey: "positioningView") as? NSView else { return false }
        return isInsideVisiblePanel(anchor)
    }

    private func isInsideVisiblePanel(_ view: NSView) -> Bool {
        guard isVisible, let panel = floatingSidebarContainerView else { return false }
        return view.isDescendant(of: panel)
    }

    func install(in parent: NSViewController) {
        parent.addChild(self)
        parent.view.addSubview(view)
        view.snp.makeConstraints { make in make.edges.equalTo(parent.view) }
    }

    /// AppKit hit-tests in subview order, independently of the layer
    /// zPosition that draws this host over its siblings, so a sibling added
    /// after it takes the clicks on the panel drawn over that sibling. Puts
    /// the host back in front when `sibling` is one of its siblings (the
    /// content fullscreen overlay). Assigning the order
    /// reorders in place: nothing leaves the window, and the other siblings
    /// keep their order.
    func bringToFront(over sibling: NSView) {
        guard isViewLoaded, let superview = view.superview, sibling.superview === superview else { return }
        superview.subviews = superview.subviews.filter { $0 !== view } + [view]
    }

    /// Keeps the open panel in place while replacing only its Space content.
    /// A slide retains the outgoing content until its band has finished moving.
    func present(_ state: BrowserState, retainingPrevious: Bool = false) {
        loadViewIfNeeded()
        if browserState !== state {
            subscriptions.removeAll()
            discardOutgoingContent()
            let previous = floatingSidebarViewController
            previous?.dismissCreateSpaceOverlay()
            browserState = state
            let bandWasVisible = isTrafficLightBandVisible
            trafficLightStrip?.removeFromSuperview()
            let strip = FloatingTrafficLightsView(browserState: state)
            strip.onStripVisibilityChanged = { [weak self] visible in
                self?.trafficLightBandVisibilityChanged(visible)
            }
            // Over the floating panel in both draw and hit-test order, so the
            // lights it carries never land on the panel's own header row.
            strip.wantsLayer = true
            strip.layer?.zPosition = WebContentContainerViewController.LayerZIndex.floatingSidebar + 1
            view.addSubview(strip)
            strip.snp.makeConstraints { make in
                make.left.right.top.equalToSuperview()
                make.height.equalTo(FloatingTrafficLightMetrics.bandHeight)
            }
            trafficLightStrip = strip
            // The new Space's band starts from the shown state the outgoing
            // one left the window in, and re-reads the pointer itself.
            strip.setStripVisible(bandWasVisible && SidebarPosition.isOnRight && !state.isInFullScreenMode)
            if bandWasVisible && !strip.isStripVisible {
                trafficLightBandVisibilityChanged(false)
            }
            // The panel's border resolves its theme through the window, and a
            // binding resolves its provider only when set or when the view
            // changes window, which it never does here. Re-bind it to the
            // Space now presented (the window's controller already is).
            panelContentView?.phiLayer?.setBorderColor(.border)
            if panelContentView != nil {
                if isVisible {
                    installContent(for: state, visible: true)
                } else if let content = content(for: state) {
                    // The panel is hidden: the presented Space's tree stays
                    // mounted (hidden) and becomes the panel's content, but
                    // its activation, layout and row realization wait for
                    // the collapse-time activation or the first hover
                    // (`ensureFloatingSidebarIfNeeded`). Doing them here
                    // cost ~120 ms of main thread on every docked Space
                    // switch, which held the switch's first frame — and the
                    // strip's motion — until after the band had landed.
                    mount(content, hidden: true)
                    floatingSidebarViewController = content
                    needsContentInstall = true
                }
                if retainingPrevious && isVisible {
                    outgoingContent = previous
                } else if previous !== floatingSidebarViewController {
                    previous?.view.isHidden = true
                }
            }
            state.sidebarWidthPublisher.sink { [weak self] width in
                if width >= MainSplitViewController.leftItemMinWidth {
                    self?.lastExpandedWidthOutsideShell = width
                }
                self?.updateFloatingSidebarWidth()
            }.store(in: &subscriptions)
            state.sidebarCollapsedPublisher.sink { [weak self] _ in
                self?.updateFloatingSidebarAvailability()
            }.store(in: &subscriptions)
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.updateFloatingSidebarAvailability() }
                .store(in: &subscriptions)
        }
        if !retainingPrevious { finishSpaceSwitch() }
    }

    // MARK: - Slide-in spring

    /// The hover slide-in lands with a small overshoot: damping ratio 0.8,
    /// about 1.5% past rest (~5 pt on a ~345 pt slide), peaking at ~0.12 s.
    static let floatingSidebarSpringStiffness: CGFloat = 2000
    static let floatingSidebarSpringDamping: CGFloat = 72
    static let floatingSidebarSpringMass: CGFloat = 1
    static let floatingSidebarSlideInAnimationKey = "floatingSidebarSlideIn"

    var prefersReducedMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Lays the panel out at rest, then plays the travel from the window edge
    /// as a spring on the layer. The model frame is final at once, so the
    /// panel is hit-testable where it lands.
    private func springFloatingSidebarIntoPlace(_ panel: NSView) {
        view.layoutSubtreeIfNeeded()
        guard let layer = panel.layer else { return }
        let spring = CASpringAnimation(keyPath: "transform.translation.x")
        spring.stiffness = Self.floatingSidebarSpringStiffness
        spring.damping = Self.floatingSidebarSpringDamping
        spring.mass = Self.floatingSidebarSpringMass
        spring.fromValue = (sidebarOnRight ? 1 : -1) * panel.frame.width
        spring.toValue = CGFloat(0)
        spring.duration = spring.settlingDuration
        spring.isRemovedOnCompletion = true
        layer.add(spring, forKey: Self.floatingSidebarSlideInAnimationKey)
    }

    /// Keep each session's content resident and active, like the docked
    /// sidebar. Initial layout runs when the session is hosted, not on return.
    func host(_ state: BrowserState) {
        loadViewIfNeeded()
        ensurePanelIfNeeded()
        guard let content = content(for: state), content.parent !== self else { return }
        mount(content, hidden: true)
        content.prepareForSpaceSwitch()
        view.layoutSubtreeIfNeeded()
    }

    /// A session leaving the shell releases its resident content permanently.
    func evictContent(for state: BrowserState) {
        for content in children.compactMap({ $0 as? FloatingSidebarViewController })
        where content.state === state {
            if outgoingContent === content { outgoingContent = nil }
            if floatingSidebarViewController === content { floatingSidebarViewController = nil }
            content.view.removeFromSuperview()
            content.removeFromParent()
            content.setContentActive(false)
        }
        if browserState === state {
            subscriptions.removeAll()
            browserState = nil
        }
    }

    /// The session's own resident content; a state without a session has
    /// nothing to host, and building a second tree here would orphan it.
    private func content(for state: BrowserState) -> FloatingSidebarViewController? {
        state.windowController?.mainSplitViewController.floatingSidebarContent
    }

    private func mount(_ content: FloatingSidebarViewController, hidden: Bool) {
        guard let panelContentView else { return }
        content.view.isHidden = hidden
        if content.parent !== self { addChild(content) }
        if content.view.superview !== panelContentView {
            panelContentView.addSubview(content.view)
            content.view.snp.makeConstraints { make in make.edges.equalToSuperview() }
        }
    }

    private func installContent(for state: BrowserState, visible: Bool = true) {
        guard let panelContentView, let content = content(for: state) else { return }
        needsContentInstall = false
        host(state)
        // A tree deactivated while its column was expanded comes back live.
        content.setContentActive(true)
        mount(content, hidden: !visible)
        content.setMediaPresented(visible && floatingSidebarContainerView?.isHidden == false)
        // Reorder without detaching the tree that was laid out before start.
        let front = Unmanaged.passUnretained(content.view).toOpaque()
        panelContentView.sortSubviews({ a, b, context in
            if Unmanaged.passUnretained(a).toOpaque() == context { return .orderedDescending }
            if Unmanaged.passUnretained(b).toOpaque() == context { return .orderedAscending }
            return .orderedSame
        }, context: front)
        floatingSidebarViewController = content
        // Resident content already has the panel's geometry. Unhiding it
        // must not relayout the glass panel and all its sibling Spaces.
        // A resized shell or a changed width still needs the outer layout.
        let panelSize = NSSize(width: currentFloatingWidth + Self.floatingSidebarInset,
                               height: max(0, view.bounds.height - 2 * Self.floatingSidebarInset))
        if floatingSidebarContainerView?.frame.size != panelSize
            || content.view.frame != panelContentView.bounds {
            view.layoutSubtreeIfNeeded()
        } else {
            content.view.layoutSubtreeIfNeeded()
        }
        content.refreshFloatingTrafficLights()
    }

    // MARK: - Dock hand-off

    /// Pinning from a visible panel, or unpinning with the shortcut while
    /// the pointer is on the column, changes one sidebar in place: the panel
    /// covers the column while the column opens or closes under it, and
    /// morphs between its inset glass shape and the column's flush shape.
    /// The shell split runs the column change and `animateSidebarHandOff()`
    /// in one animation group: the column at the sidebar toggle's speed and curve
    /// (`SidebarToggleAnimation`), the panel gliding over the same time on
    /// the same curve, so the two move as one.
    static let sidebarHandOffDuration: TimeInterval = SidebarToggleAnimation.duration
    /// After a dock the panel fades off the open column it covers.
    static let sidebarHandOffFadeDuration: TimeInterval = SidebarToggleAnimation.duration
    /// How far past its edge the resting panel's shadow reaches.
    static let panelShadowReach: CGFloat = 40
    /// How far the docked glass reaches past the window's edges, with its
    /// rows inset by as much. The glass draws a rim just inside its edge;
    /// on the window's edge that rim would show as a second line inside the
    /// window's own border.
    static let dockedGlassOverhang: CGFloat = 5
    /// How far inside the panel's border the column material sheet sits.
    static let columnMaterialSheetInset: CGFloat = 1
    /// The share of a dock's glide the shadow clip takes to close.
    static let dockingClipShare: Double = 0.6
    /// The rows the docked shape insets, so they go back when it ends.
    private weak var dockedRows: NSView?

    private var sidebarHandOff: SidebarHandOffKind?
    private var sidebarHandOffGeneration = 0
    /// The column's material, under the panel's content. The panel's glass
    /// over the open column reads brighter than the column alone (it adapts
    /// to what is under it and adds its own light), so a hand-off would end
    /// on a flash as the panel goes. A dock fades the sheet in while the
    /// panel moves; an undock starts with it and fades it out. Whenever the
    /// panel covers the column, it then looks like the column.
    private var columnMaterialSheet: NSVisualEffectView?

    /// The window's own lights, in its titlebar.
    private var titlebarButtons: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap {
            view.window?.titlebarButton($0)
        }
    }

    var isSidebarHandOffRunning: Bool { sidebarHandOff != nil }

    /// The docked column's sidebar for the presented session.
    private var columnSidebar: MainSplitViewController? {
        browserState?.windowController?.mainSplitViewController
    }

    /// Puts the panel in place as the cover. Returns false, changing nothing,
    /// when this toggle is not a hand-off: no floating panel in this layout,
    /// or a dock with the panel hidden.
    func beginSidebarHandOff(_ kind: SidebarHandOffKind) -> Bool {
        guard sidebarHandOff == nil, browserState != nil,
              PhiPreferences.GeneralSettings.loadLayoutMode() != .comfortable else { return false }
        switch kind {
        case .dock:
            guard isVisible else { return false }
            cancelFloatingSidebarHide()
            // A slide-out in flight stops, and the group's layout brings the
            // panel back to the edge.
            visibilityGeneration += 1
            floatingSidebarLeadingConstraint?.update(offset: 0)
            floatingSidebarViewController?.setKeepsTrafficLightsForHandOff(true)
            // The column the panel fades off shows the rows the panel showed.
            if let panelOffset = floatingSidebarViewController?.tabListScrollOffset {
                columnSidebar?.sidebarTabListScrollOffset = panelOffset
            }
        case .undock:
            ensureFloatingSidebarIfNeeded()
            guard let panel = floatingSidebarContainerView else { return false }
            ensureFloatingSidebarOcclusionObserver()
            cancelFloatingSidebarHide()
            floatingSidebarViewController?.setContentActive(true)
            realizeHiddenContent()
            visibilityGeneration += 1
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            floatingSidebarLeadingConstraint?.update(offset: 0)
            // The panel's lights exist, on the window's, before the glide
            // reads where everything starts: made only once the collapsed
            // state arrives, they'd start off their spot.
            floatingSidebarViewController?.setKeepsTrafficLightsForHandOff(true)
            applyPanelShape(docked: true)
            view.layoutSubtreeIfNeeded()
            // The panel shows the rows the column showed, not its own last
            // position.
            if let columnOffset = columnSidebar?.sidebarTabListScrollOffset {
                floatingSidebarViewController?.tabListScrollOffset = columnOffset
            }
            // It appears looking like the column, and the window's lights go
            // as the panel's appear on them; until the collapsed state reaches
            // the titlebar a pass later, both would show a pixel apart. Layer
            // opacity only: showing or hiding them re-tiles the titlebar.
            columnMaterialSheet?.alphaValue = 1
            titlebarButtons.forEach { $0.layer?.opacity = 0 }
            panel.isHidden = false
            CATransaction.commit()
            floatingSidebarViewController?.setMediaPresented(true)
            floatingSidebarViewController?.refreshFloatingTrafficLights()
            isPointerInsideFloatingSidebar = true
        }
        // The cover holds still over the column: no slide-in or fade runs on.
        floatingSidebarContainerView?.layer?.removeAllAnimations()
        sidebarHandOff = kind
        sidebarHandOffGeneration += 1
        return true
    }

    /// Call inside the animation group that changes the column. The panel
    /// glides to the column's shape while the column opens under it (dock),
    /// or to its inset glass shape while the column closes (undock).
    func animateSidebarHandOff() {
        guard let kind = sidebarHandOff else { return }
        applyPanelShape(docked: kind == .dock, glideDuration: Self.sidebarHandOffDuration)
        fadeColumnMaterialSheet(in: kind == .dock)
    }

    /// Explicit: on an undock the sheet was shown in this same pass and never
    /// drawn, so an implicit fade would start from its old, clear value.
    private func fadeColumnMaterialSheet(in fadesIn: Bool) {
        guard let sheet = columnMaterialSheet, let layer = sheet.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fadesIn ? 0 : 1
        fade.toValue = fadesIn ? 1 : 0
        fade.duration = Self.sidebarHandOffDuration
        fade.timingFunction = SidebarToggleAnimation.timingFunction
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sheet.alphaValue = fadesIn ? 1 : 0
        CATransaction.commit()
        layer.add(fade, forKey: "columnMaterialSheet")
    }

    /// Ends the hand-off once the column has changed. A dock fades the panel
    /// off the open column it now matches. Safe to call when nothing runs.
    func finishSidebarHandOff() {
        guard !prefersReducedMotion(), sidebarHandOff == .dock,
              let panel = floatingSidebarContainerView, isVisible else {
            completeSidebarHandOff()
            return
        }
        let generation = sidebarHandOffGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.sidebarHandOffFadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, sidebarHandOffGeneration == generation else { return }
            completeSidebarHandOff()
        })
    }

    /// Jumps a running hand-off to its end state, with no fade.
    func finishSidebarHandOffImmediately() {
        completeSidebarHandOff()
    }

    private func completeSidebarHandOff() {
        guard let kind = sidebarHandOff else { return }
        sidebarHandOff = nil
        sidebarHandOffGeneration += 1
        columnMaterialSheet?.alphaValue = 0
        floatingSidebarViewController?.setKeepsTrafficLightsForHandOff(false)
        titlebarButtons.forEach { $0.layer?.opacity = 1 }
        switch kind {
        case .dock:
            hideFloatingSidebar(animated: false)
            floatingSidebarContainerView?.alphaValue = 1
            applyPanelShape(docked: false)
        case .undock:
            applyPanelShape(docked: false)
            // The border, left out of the glide, fades in at rest.
            if !prefersReducedMotion(), let layer = panelContentView?.layer {
                let fade = CABasicAnimation(keyPath: "borderWidth")
                fade.fromValue = 0
                fade.toValue = layer.borderWidth
                fade.duration = Self.sidebarHandOffFadeDuration
                layer.add(fade, forKey: "borderIn")
            }
            // From here the panel follows the hover rules, and its minimum
            // visible time counts from now.
            floatingSidebarLastShownAt = Date()
            refreshFloatingSidebarPointerState()
            if !isPointerInsideFloatingSidebar { scheduleFloatingSidebarHide() }
        }
        updateFloatingSidebarAvailability()
    }

    /// Resting: the inset glass panel with the floating header's spacing.
    /// Docked: the column's frame (flush with the window's outer edge, top
    /// and bottom, square, no border) and the column's header layout.
    ///
    /// With `glideDuration`, every view in the panel glides from where it is
    /// on screen to its new frame. AppKit's implicit animation would grow
    /// the views' sizes but jump their positions, so the content would snap
    /// while the glass grew around it; the glide animates the layers
    /// explicitly instead.
    private func applyPanelShape(docked: Bool, glideDuration: TimeInterval? = nil) {
        guard let visual = panelVisualContainer else { return }
        let start = glideDuration == nil ? nil : floatingSidebarContainerView.map(Self.layerGeometry(in:))
        let startRadius = panelContentView?.layer.map { Self.shown($0).cornerRadius }
        let startClip = glideDuration == nil ? nil : shadowClipFrame(docked: false)
        let inset = Self.floatingSidebarInset
        let right = sidebarOnRight
        let radius = docked ? 0 : LiquidGlassCompatible.webContentContainerCornerRadius
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            let overhang = Self.dockedGlassOverhang
            visual.snp.remakeConstraints { make in
                if docked {
                    make.top.equalToSuperview().offset(-inset - overhang)
                    make.bottom.equalToSuperview().offset(inset + overhang)
                    make.left.equalToSuperview().offset(right ? inset : -overhang)
                    make.right.equalToSuperview().offset(right ? overhang : -inset)
                } else {
                    make.top.bottom.equalToSuperview()
                    make.left.equalToSuperview().offset(right ? 0 : inset)
                    make.right.equalToSuperview().offset(right ? -inset : 0)
                }
            }
            floatingSidebarViewController?.setUsesDockedHeaderMetrics(docked)
            insetRows(docked: docked)
            panelContentView?.layer?.cornerRadius = radius
            // No border while a hand-off glides: it would show as a line on
            // the panel's top edge.
            panelContentView?.layer?.borderWidth = docked || glideDuration != nil ? 0 : 1
            columnMaterialSheet?.layer?.cornerRadius = max(radius - Self.columnMaterialSheetInset, 0)
            view.layoutSubtreeIfNeeded()
        }
        let glassRadius: CGFloat = docked ? 0 : 14
        let clip = shadowClip(docked: docked, gliding: glideDuration != nil)
        guard let glideDuration, let start else {
            glassRadiusTimer?.invalidate()
            glassRadiusTimer = nil
            if #available(macOS 26.0, *), let glass = visual as? NSGlassEffectView {
                glass.cornerRadius = glassRadius
            }
            return
        }
        // The column's curve, so the panel and the column move as one.
        func glide(_ layer: CALayer, _ keyPath: String, from: Any, to: Any, duration: TimeInterval = glideDuration,
                   timing: CAMediaTimingFunction = SidebarToggleAnimation.timingFunction) {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = duration
            animation.timingFunction = timing
            // A view's own layer takes the curve of the animation group it
            // is added in, which the split opens with its own curve.
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.timingFunction = animation.timingFunction
            layer.add(animation, forKey: "sidebarHandOff.\(keyPath)")
            NSAnimationContext.endGrouping()
        }
        for (layer, position, bounds) in start {
            if layer.position != position {
                glide(layer, "position", from: NSValue(point: position), to: NSValue(point: layer.position))
            }
            if layer.bounds != bounds {
                glide(layer, "bounds", from: NSValue(rect: bounds), to: NSValue(rect: layer.bounds))
            }
        }
        if let layer = panelContentView?.layer, let startRadius, startRadius != radius {
            glide(layer, "cornerRadius", from: startRadius, to: radius)
            if let sheet = columnMaterialSheet?.layer {
                let inset = Self.columnMaterialSheetInset
                glide(sheet, "cornerRadius", from: max(startRadius - inset, 0), to: max(radius - inset, 0))
            }
        }
        if let clip, let startClip, startClip != clip.frame {
            // Docking, the clip covers the rim before the panel slows into
            // the column's place, where a rim would read as a line on the
            // column's edge.
            // Undocking, it opens slowly at first, so the shadow comes out
            // as the panel leaves the column, not on the click.
            let clipDuration = docked ? glideDuration * Self.dockingClipShare : glideDuration
            let clipTiming = CAMediaTimingFunction(name: docked ? .easeOut : .easeIn)
            glide(clip, "position", from: NSValue(point: NSPoint(x: startClip.midX, y: startClip.midY)),
                  to: NSValue(point: clip.position), duration: clipDuration, timing: clipTiming)
            glide(clip, "bounds", from: NSValue(rect: NSRect(origin: .zero, size: startClip.size)),
                  to: NSValue(rect: clip.bounds), duration: clipDuration, timing: clipTiming)
        }
        if #available(macOS 26.0, *), let glass = visual as? NSGlassEffectView {
            stepCornerRadius(of: glass, to: glassRadius, duration: glideDuration)
        }
    }

    private var glassRadiusTimer: Timer?

    /// Docked, the presented rows sit inset by the glass's overhang on the
    /// window's sides, so they cover the column exactly. At rest they fill
    /// the glass again.
    private func insetRows(docked: Bool) {
        let rows = docked ? floatingSidebarViewController?.view : dockedRows
        guard let rows, rows.superview === panelContentView else { return }
        let overhang = docked ? Self.dockedGlassOverhang : 0
        let right = sidebarOnRight
        rows.snp.remakeConstraints { make in
            make.top.bottom.equalToSuperview().inset(overhang)
            make.left.equalToSuperview().inset(right ? 0 : overhang)
            make.right.equalToSuperview().inset(right ? overhang : 0)
        }
        dockedRows = docked ? rows : nil
    }

    /// Where the shadow clip stands now, on screen. With no clip, the
    /// resting clip for the panel's current frame, which clips nothing.
    private func shadowClipFrame(docked: Bool) -> NSRect? {
        if let clip = floatingSidebarContainerView?.layer?.mask {
            return Self.shown(clip).frame
        }
        return shadowClipTarget(docked: docked)
    }

    /// The clip for each shape. Docked, it ends at the panel's outer edge,
    /// so no shadow shows on the column's edge; the column material sheet
    /// covers the glass there. At rest it leaves the whole shadow out. Top,
    /// bottom and the window side are never clipped.
    private func shadowClipTarget(docked: Bool) -> NSRect? {
        guard let panel = floatingSidebarContainerView, let visual = panelVisualContainer else { return nil }
        let far: CGFloat = 10_000
        let reach = docked ? 0 : Self.panelShadowReach
        let y = -far
        let height = panel.bounds.height + 2 * far
        if sidebarOnRight {
            let minX = visual.frame.minX - reach
            return NSRect(x: minX, y: y, width: far - minX, height: height)
        }
        return NSRect(x: -far, y: y, width: visual.frame.maxX + reach + far, height: height)
    }

    /// Sets the panel's shadow clip for `docked`, and returns it. A resting
    /// panel that does not glide needs no clip, and has it removed.
    private func shadowClip(docked: Bool, gliding: Bool) -> CALayer? {
        guard let layer = floatingSidebarContainerView?.layer else { return nil }
        guard docked || gliding, let target = shadowClipTarget(docked: docked) else {
            layer.mask = nil
            return nil
        }
        let clip = layer.mask ?? {
            let clip = CALayer()
            clip.backgroundColor = NSColor.black.cgColor
            return clip
        }()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.removeAllAnimations()
        clip.frame = target
        layer.mask = clip
        CATransaction.commit()
        return clip
    }

    /// The glass redraws its rounded edge from `cornerRadius` but does not
    /// animate it, so the glide sets it once a frame, eased out like the
    /// layers.
    @available(macOS 26.0, *)
    private func stepCornerRadius(of glass: NSGlassEffectView, to target: CGFloat, duration: TimeInterval) {
        glassRadiusTimer?.invalidate()
        glassRadiusTimer = nil
        let start = glass.cornerRadius
        guard start != target else { return }
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self, weak glass] timer in
            MainActor.assumeIsolated {
                guard let glass else {
                    timer.invalidate()
                    return
                }
                let progress = min(1, (CACurrentMediaTime() - began) / duration)
                let eased = 1 - (1 - progress) * (1 - progress)
                glass.cornerRadius = start + (target - start) * eased
                guard progress >= 1 else { return }
                timer.invalidate()
                self?.glassRadiusTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        glassRadiusTimer = timer
    }

    /// `layer` as it is now. A layer in motion is where its animation shows
    /// it. Any other layer is as its latest change left it: an undock sets
    /// the panel up over the column and glides it in the same turn, before a
    /// frame draws, and the presentation layer still shows the last frame
    /// drawn, from the panel's previous showing (off screen, rounded,
    /// bordered).
    private static func shown(_ layer: CALayer) -> CALayer {
        guard layer.animationKeys()?.isEmpty == false else { return layer }
        return layer.presentation() ?? layer
    }

    /// Where each layer in `root`'s tree is now, by `shown(_:)`.
    ///
    /// Views without a layer get one first. An undock shows the panel in the
    /// same pass, before AppKit has given its list's scroll view, clip view
    /// and rows layers; left out, they'd sit at their end frames inside a
    /// gliding parent, and the rows would dip at the lift. Layers a view draws
    /// with that are not views, such as the glass effect's own, glide too;
    /// left out, the glass would show past the panel's content while a dock
    /// widens it.
    private static func layerGeometry(in root: NSView) -> [(CALayer, CGPoint, CGRect)] {
        var geometry: [(CALayer, CGPoint, CGRect)] = []
        var viewLayers = Set<ObjectIdentifier>()
        func prepare(_ view: NSView) {
            if view.layer == nil { view.wantsLayer = true }
            if let layer = view.layer { viewLayers.insert(ObjectIdentifier(layer)) }
            view.subviews.forEach(prepare)
        }
        func collectInner(_ layer: CALayer) {
            for sublayer in layer.sublayers ?? [] where !viewLayers.contains(ObjectIdentifier(sublayer)) {
                let shown = Self.shown(sublayer)
                geometry.append((sublayer, shown.position, shown.bounds))
                collectInner(sublayer)
            }
        }
        func collect(_ view: NSView) {
            if let layer = view.layer {
                let shown = Self.shown(layer)
                geometry.append((layer, shown.position, shown.bounds))
                collectInner(layer)
            }
            view.subviews.forEach(collect)
        }
        prepare(root)
        collect(root)
        return geometry
    }

    func beginSpaceSwitch() {
        finishSidebarHandOffImmediately()
        isSwitchingSpace = true
        cancelFloatingSidebarHide()
        // Cancel an already-running hide completion as well as its timer.
        visibilityGeneration += 1
        if isVisible, floatingSidebarLeadingConstraint?.layoutConstraints.first?.constant != 0 {
            floatingSidebarLeadingConstraint?.update(offset: 0)
            view.layoutSubtreeIfNeeded()
        }
    }

    func finishSpaceSwitch() {
        let wasSwitching = isSwitchingSpace
        isSwitchingSpace = false
        discardOutgoingContent()
        if wasSwitching && isVisible { scheduleFloatingSidebarHide() }
    }

    private func discardOutgoingContent() {
        outgoingContent?.view.isHidden = true
        outgoingContent = nil
    }

    deinit {
        floatingSidebarHideWorkItem?.cancel()
        floatingSidebarEnableWorkItem?.cancel()
        if let observer = floatingSidebarOcclusionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        floatingSidebarGeometryObservers.forEach { NotificationCenter.default.removeObserver($0) }
        popoverObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    static let floatingSidebarDefaultWidth: CGFloat = MainSplitViewController.leftItemMinWidth
    static let floatingSidebarTriggerWidth: CGFloat = 10
    static let floatingSidebarHideDelay: TimeInterval = 0.12
    static let floatingSidebarMinimumVisibleDuration: TimeInterval = 0.5
    static let floatingSidebarInset: CGFloat = 5
    private static let floatingSidebarShowDuration: TimeInterval = 0.15
    static let floatingSidebarHideDuration: TimeInterval = 0.15
    /// Quiet period after the docked column's last width change before the
    /// hidden panel follows it; shorter than the trigger's enable delay after
    /// a collapse, so a deferred sync lands before the panel can first show.
    static let floatingSidebarWidthSyncDelay: TimeInterval = 0.25
    /// The resize strip is as wide as the docked column's divider, half of it
    /// inside the panel and half past its edge.
    static let floatingSidebarResizeHandleWidth: CGFloat = PhiSplitViewController.dividerHitThickness
    /// How far past the panel's inner edge the pointer can stray before the
    /// panel closes. It covers the resize strip's outer half.
    static let floatingSidebarEdgeBufferWidth: CGFloat = 10

    /// The column's last expanded width as the bound state reported it; the
    /// source for a host outside a shell (a standalone Incognito window),
    /// which has no shell split to ask.
    private var lastExpandedWidthOutsideShell: CGFloat = 0

    var currentFloatingWidth: CGFloat {
        // The panel only appears while the column is collapsed, so it opens
        // at the width the column had when last expanded: the shell split's
        // record, the same source the docked column resizes from.
        if let split = parent as? ShellSplitViewController {
            if split.lastExpandedSidebarWidth >= MainSplitViewController.leftItemMinWidth {
                return split.lastExpandedSidebarWidth
            }
        } else if lastExpandedWidthOutsideShell >= MainSplitViewController.leftItemMinWidth {
            return lastExpandedWidthOutsideShell
        }
        return Self.floatingSidebarDefaultWidth
    }

    var floatingSidebarHiddenLeading: CGFloat {
        (sidebarOnRight ? 1 : -1) * (currentFloatingWidth + Self.floatingSidebarInset)
    }

    func setupFloatingSidebarTrigger() {
        floatingSidebarTriggerView.onMouseEntered = { [weak self] event in
            guard let self else { return }
            isPointerInsideFloatingSidebarTrigger = true
            pointerTouchedFloatingSidebar = true
            showFloatingSidebar()
        }

        floatingSidebarTriggerView.onMouseExited = { [weak self] event in
            guard let self else { return }
            isPointerInsideFloatingSidebarTrigger = false
            if isInsideFloatingSidebarVisibleRegion(event.locationInWindow) {
                pointerEnteredWindowThroughStrip = false
            }
            scheduleFloatingSidebarHide()
        }
    }

    /// The pointer crossed the window's edge into it (`FloatingSidebarOverlayView`).
    func pointerEnteredWindow(at location: NSPoint) {
        let strip = floatingSidebarTriggerView.convert(floatingSidebarTriggerView.bounds, to: nil)
        pointerEnteredWindowThroughStrip = strip.contains(location)
    }

    /// A fast pointer can cross the strip between two mouse events and leave
    /// the window without the strip seeing it. Leaving past the sidebar's
    /// edge, level with the strip, still reveals the panel, as a slower
    /// pointer crossing the strip on its way out does.
    func pointerLeftWindow(at location: NSPoint) {
        guard !isShownOrShowing, !floatingSidebarTriggerView.isHidden else { return }
        let strip = floatingSidebarTriggerView.convert(floatingSidebarTriggerView.bounds, to: nil)
        guard Self.isPastFloatingSidebarEdge(location, strip: strip, sidebarOnRight: sidebarOnRight) else { return }
        pointerTouchedFloatingSidebar = true
        pointerEnteredWindowThroughStrip = false
        showFloatingSidebar()
        scheduleFloatingSidebarHide()
    }

    /// Whether `location` lies past the window's edge on the sidebar's side,
    /// level with the strip at `strip`.
    static func isPastFloatingSidebarEdge(_ location: NSPoint, strip: NSRect, sidebarOnRight: Bool) -> Bool {
        let level = location.y >= strip.minY && location.y <= strip.maxY
        return level && (sidebarOnRight ? location.x >= strip.maxX : location.x < strip.minX)
    }

    func shouldEnableFloatingSidebar() -> Bool {
        guard let state = browserState else { return false }
        let layoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()
        return layoutMode != .comfortable && state.sidebarCollapsed
    }

    func ensureFloatingSidebarIfNeeded() {
        guard let state = browserState else { return }
        ensurePanelIfNeeded()
        if floatingSidebarViewController == nil || needsContentInstall {
            installContent(for: state)
        } else {
            floatingSidebarViewController?.view.isHidden = false
        }
    }

    private func ensurePanelIfNeeded() {
        guard floatingSidebarContainerView == nil else { return }
        updateSidebarPosition()
        let interactionContainerView = MouseTrackingAreaView()
        interactionContainerView.onMouseEntered = { [weak self] event in
            guard let self else { return }
            refreshFloatingSidebarPointerState()
            if isInsideFloatingSidebarVisibleRegion(event.locationInWindow) {
                pointerTouchedFloatingSidebar = true
                pointerEnteredWindowThroughStrip = false
            }
            if isPointerInsideFloatingSidebar {
                cancelFloatingSidebarHide()
            }
        }

        interactionContainerView.onMouseExited = { [weak self] _ in
            guard let self else { return }
            isPointerInsideFloatingSidebar = false
            scheduleFloatingSidebarHide()
        }

        let panelContentView = NSView()
        panelContentView.wantsLayer = true
        panelContentView.layer?.cornerRadius = LiquidGlassCompatible.webContentContainerCornerRadius
        panelContentView.layer?.masksToBounds = true
        panelContentView.phiLayer?.setBorderColor(.border)
        panelContentView.layer?.borderWidth = 1

        // Below the sidebar content, which mounts later
        // (`columnMaterialSheet`).
        let sheet = NSVisualEffectView()
        sheet.material = .fullScreenUI
        sheet.blendingMode = .behindWindow
        sheet.wantsLayer = true
        sheet.alphaValue = 0
        sheet.layer?.masksToBounds = true
        sheet.layer?.cornerCurve = panelContentView.layer?.cornerCurve ?? .circular
        sheet.layer?.cornerRadius = LiquidGlassCompatible.webContentContainerCornerRadius - Self.columnMaterialSheetInset
        panelContentView.addSubview(sheet)
        sheet.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(Self.columnMaterialSheetInset)
        }
        columnMaterialSheet = sheet

        self.panelContentView = panelContentView

        let panelVisualContainer: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            // Its own layer from the start: a dock or undock glides the
            // layer, and a layer AppKit makes at the next commit would miss
            // the first undock's glide.
            glass.wantsLayer = true
            glass.contentView = panelContentView
            glass.cornerRadius = 14
            glass.style = .regular
            panelVisualContainer = glass
        } else {
            panelVisualContainer = panelContentView
        }

        self.panelVisualContainer = panelVisualContainer
        interactionContainerView.addSubview(panelVisualContainer)
        panelVisualContainer.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(sidebarOnRight ? 0 : Self.floatingSidebarInset)
            make.right.equalToSuperview().offset(sidebarOnRight ? -Self.floatingSidebarInset : 0)
            make.top.bottom.equalToSuperview()
        }

        // Sit above `outerBorderLayer` (zPosition = contentOuterBorder) so the
        // unified content-border stroke doesn't paint on top of the panel
        // when it slides in over the web content.
        interactionContainerView.wantsLayer = true
        interactionContainerView.layer?.zPosition = WebContentContainerViewController.LayerZIndex.floatingSidebar

        if let trafficLightStrip {
            view.addSubview(interactionContainerView, positioned: .below, relativeTo: trafficLightStrip)
        } else {
            view.addSubview(interactionContainerView, positioned: .above, relativeTo: nil)
        }
        interactionContainerView.snp.makeConstraints { make in
            if sidebarOnRight {
                floatingSidebarLeadingConstraint = make.right.equalToSuperview().offset(floatingSidebarHiddenLeading).constraint
            } else {
                floatingSidebarLeadingConstraint = make.left.equalToSuperview().offset(floatingSidebarHiddenLeading).constraint
            }
            make.top.equalToSuperview().offset(Self.floatingSidebarInset)
            make.bottom.equalToSuperview().offset(-Self.floatingSidebarInset)
            floatingSidebarWidthConstraint = make.width.equalTo(currentFloatingWidth + Self.floatingSidebarInset).constraint
        }

        // Centered on the panel's inner edge, reaching past it as far as
        // into it, like the docked column's divider. A sibling of the panel
        // rather than its subview, so the half outside the panel takes
        // clicks too; it follows the panel's visibility.
        let resizeHandle = FloatingSidebarResizeHandleView()
        resizeHandle.wantsLayer = true
        resizeHandle.layer?.zPosition = WebContentContainerViewController.LayerZIndex.floatingSidebar
        resizeHandle.onBegin = { [weak self] in self?.beginFloatingSidebarResize() }
        resizeHandle.onDrag = { [weak self] offset in
            guard let self else { return }
            resizeFloatingSidebar(toWidth: Self.floatingSidebarWidth(
                from: floatingSidebarResizeStartWidth, dragOffset: offset, sidebarOnRight: sidebarOnRight))
        }
        resizeHandle.onEnd = { [weak self] in self?.endFloatingSidebarResize() }
        resizeHandle.directions = { [weak self] in
            guard let self else { return .both }
            return Self.floatingSidebarResizeDirections(forWidth: currentFloatingWidth, sidebarOnRight: sidebarOnRight)
        }
        view.addSubview(resizeHandle, positioned: .above, relativeTo: interactionContainerView)
        floatingSidebarResizeHandle = resizeHandle
        layoutResizeHandle(on: interactionContainerView)
        resizeHandleVisibility = interactionContainerView.publisher(for: \.isHidden)
            .sink { [weak resizeHandle] isHidden in resizeHandle?.isHidden = isHidden }

        view.layoutSubtreeIfNeeded()
        interactionContainerView.isHidden = true
        interactionContainerView.alphaValue = 1

        floatingSidebarContainerView = interactionContainerView
    }

    /// Window occlusion may dismiss the panel; changing the presented Space
    /// does not occlude or replace this window-owned view.
    private func ensureFloatingSidebarOcclusionObserver() {
        guard floatingSidebarOcclusionObserver == nil, let window = view.window else { return }
        floatingSidebarOcclusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.view.window?.isVisible == false else { return }
            self.hideFloatingSidebar(animated: false)
        }
    }

    /// A window resize (zoom, entering or leaving full screen) can move the
    /// panel out from under a stationary pointer. macOS 27 rebuilds the
    /// tracking areas for the new geometry without sending the exit the
    /// pointer's departure implies, so the panel would stay up until the
    /// pointer crossed it again; it re-reads the pointer itself instead.
    private func ensureFloatingSidebarGeometryObservers() {
        guard floatingSidebarGeometryObservers.isEmpty, let window = view.window else { return }
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
        ]
        floatingSidebarGeometryObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.floatingSidebarWindowGeometryDidChange()
            }
        }
    }

    private func floatingSidebarWindowGeometryDidChange() {
        guard let panel = floatingSidebarContainerView, panel.isHidden == false else { return }
        applyFloatingSidebarWidth()
        refreshFloatingSidebarPointerState()
        guard !isPointerInsideFloatingSidebar, !isPointerInsideFloatingSidebarTrigger else { return }
        // The delayed hide checks the pointer again when it fires; a later
        // resize in the same transition replaces it, so the settled geometry
        // decides.
        scheduleFloatingSidebarHide()
    }

    /// Syncs the hidden panel to the docked column's width.
    ///
    /// While the column is expanded the panel cannot show, and a divider drag
    /// changes the column's width on every frame: laying the hidden panel and
    /// its resident trees out at each of those widths cost about a quarter of
    /// every drag frame. The sync is deferred until the drag settles instead.
    /// Collapsing the column, and showing the panel, apply it at once.
    func updateFloatingSidebarWidth() {
        floatingSidebarWidthSyncWorkItem?.cancel()
        floatingSidebarWidthSyncWorkItem = nil
        guard isVisible || browserState?.sidebarCollapsed != false else {
            let workItem = DispatchWorkItem { [weak self] in
                self?.floatingSidebarWidthSyncWorkItem = nil
                self?.applyFloatingSidebarWidth()
            }
            floatingSidebarWidthSyncWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.floatingSidebarWidthSyncDelay,
                execute: workItem
            )
            return
        }
        applyFloatingSidebarWidth()
    }

    /// Brings the panel to its width now, ahead of any sync
    /// `updateFloatingSidebarWidth` deferred. The width also follows the
    /// window's, which changes while the panel is hidden without a sync.
    private func flushPendingFloatingSidebarWidthSync() {
        floatingSidebarWidthSyncWorkItem?.cancel()
        floatingSidebarWidthSyncWorkItem = nil
        applyFloatingSidebarWidth()
    }

    private func applyFloatingSidebarWidth() {
        let width = currentFloatingWidth + Self.floatingSidebarInset
        guard floatingSidebarWidthConstraint?.layoutConstraints.first?.constant != width else { return }
        floatingSidebarWidthConstraint?.update(offset: width)
        // The panel and its resident trees take the new width now, hidden,
        // rather than on the first show.
        view.layoutSubtreeIfNeeded()
    }

    private func updateSidebarPosition() {
        let right = SidebarPosition.isOnRight
        guard right != sidebarOnRight else { return }
        hideFloatingSidebar(animated: false)
        sidebarOnRight = right
        floatingSidebarTriggerView.snp.remakeConstraints { make in
            make.top.bottom.equalToSuperview()
            if right { make.right.equalToSuperview() } else { make.left.equalToSuperview() }
            make.width.equalTo(Self.floatingSidebarTriggerWidth)
        }
        if let panel = floatingSidebarContainerView {
            panel.snp.remakeConstraints { make in
                if right {
                    floatingSidebarLeadingConstraint = make.right.equalToSuperview().offset(floatingSidebarHiddenLeading).constraint
                } else {
                    floatingSidebarLeadingConstraint = make.left.equalToSuperview().offset(floatingSidebarHiddenLeading).constraint
                }
                make.top.bottom.equalToSuperview().inset(Self.floatingSidebarInset)
                floatingSidebarWidthConstraint = make.width.equalTo(currentFloatingWidth + Self.floatingSidebarInset).constraint
            }
            panelVisualContainer?.snp.remakeConstraints { make in
                make.top.bottom.equalToSuperview()
                make.left.equalToSuperview().offset(right ? 0 : Self.floatingSidebarInset)
                make.right.equalToSuperview().offset(right ? -Self.floatingSidebarInset : 0)
            }
            layoutResizeHandle(on: panel)
        }
    }

    /// Centers the resize strip on the panel's inner edge: its right edge
    /// with the sidebar on the left, its left edge with the sidebar on the
    /// right.
    private func layoutResizeHandle(on panel: NSView) {
        guard let handle = floatingSidebarResizeHandle else { return }
        handle.snp.remakeConstraints { make in
            make.top.bottom.equalTo(panel)
            make.centerX.equalTo(sidebarOnRight ? panel.snp.left : panel.snp.right)
            make.width.equalTo(Self.floatingSidebarResizeHandleWidth)
        }
    }

    /// Starts a resize of the panel by its inner edge.
    func beginFloatingSidebarResize() {
        isResizingFloatingSidebar = true
        floatingSidebarResizeStartWidth = currentFloatingWidth
        cancelFloatingSidebarHide()
    }

    /// Resizes the panel to `width`, within the docked column's limits. The
    /// panel and the column share one width, so the column's owner takes it
    /// as well: the column docks at it.
    func resizeFloatingSidebar(toWidth width: CGFloat) {
        let clamped = min(max(width, MainSplitViewController.leftItemMinWidth),
                          MainSplitViewController.leftItemMaxWidth)
        if let split = parent as? ShellSplitViewController {
            split.adoptFloatingSidebarWidth(clamped)
        } else {
            lastExpandedWidthOutsideShell = clamped
            browserState?.windowController?.mainSplitViewController.adoptFloatingSidebarWidth(clamped)
        }
        applyFloatingSidebarWidth()
    }

    /// Ends a resize. The panel closes as usual if the pointer is outside it.
    func endFloatingSidebarResize() {
        guard isResizingFloatingSidebar else { return }
        isResizingFloatingSidebar = false
        scheduleFloatingSidebarHide()
    }

    func updateFloatingSidebarAvailability() {
        updateSidebarPosition()
        let shouldEnable = shouldEnableFloatingSidebar()
        // The hand-off owns the panel until it finishes, then runs this again.
        guard sidebarHandOff == nil else { return }

        floatingSidebarEnableWorkItem?.cancel()
        floatingSidebarEnableWorkItem = nil

        if !shouldEnable {
            floatingSidebarTriggerView.isHidden = true
            isPointerInsideFloatingSidebar = false
            isPointerInsideFloatingSidebarTrigger = false
            floatingSidebarViewController?.setContentActive(false)
            hideFloatingSidebar(animated: false)
        } else if floatingSidebarTriggerView.isHidden {
            floatingSidebarViewController?.setContentActive(true)
            realizeHiddenContent()
            // Delay enabling trigger to avoid activation during sidebar collapse animation.
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.shouldEnableFloatingSidebar() else { return }
                self.floatingSidebarTriggerView.isHidden = false
            }
            floatingSidebarEnableWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
        }
    }

    /// Rows, hosted SwiftUI heights and the pinned band only form while a
    /// view is visible. Form them now, off screen, so the slide moves a
    /// finished panel instead of one that grows into shape.
    private func realizeHiddenContent() {
        flushPendingFloatingSidebarWidthSync()
        if needsContentInstall, let state = browserState {
            installContent(for: state, visible: false)
        }
        guard let panel = floatingSidebarContainerView, panel.isHidden,
              let content = floatingSidebarViewController else { return }
        let contentWasHidden = content.view.isHidden
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.isHidden = false
        content.view.isHidden = false
        content.prepareSpaceSwitchBand()
        content.view.isHidden = contentWasHidden
        panel.isHidden = true
        CATransaction.commit()
    }

    func showFloatingSidebar() {
        guard shouldEnableFloatingSidebar() else { return }
        flushPendingFloatingSidebarWidthSync()
        ensureFloatingSidebarIfNeeded()
        ensureFloatingSidebarOcclusionObserver()
        ensureFloatingSidebarGeometryObservers()
        cancelFloatingSidebarHide()

        guard let panel = floatingSidebarContainerView else { return }
        visibilityGeneration += 1
        let reduceMotion = prefersReducedMotion()
        let wasHiding = isFloatingSidebarHideAnimating
        isFloatingSidebarHideAnimating = false
        guard panel.isHidden else {
            floatingSidebarViewController?.setMediaPresented(true)
            floatingSidebarLeadingConstraint?.update(offset: 0)
            if wasHiding, !reduceMotion {
                // Slide back from where the hide got to, rather than jump.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.floatingSidebarShowDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    context.allowsImplicitAnimation = true
                    self.view.layoutSubtreeIfNeeded()
                }
            } else {
                view.layoutSubtreeIfNeeded()
                if wasHiding {
                    panel.layer?.removeAllAnimations()
                    floatingSidebarResizeHandle?.layer?.removeAllAnimations()
                }
            }
            return
        }

        floatingSidebarLeadingConstraint?.update(offset: reduceMotion ? 0 : floatingSidebarHiddenLeading)
        view.layoutSubtreeIfNeeded()
        panel.isHidden = false
        floatingSidebarViewController?.setMediaPresented(true)
        floatingSidebarLastShownAt = Date()
        floatingSidebarViewController?.refreshFloatingTrafficLights()

        // Handle the case where the panel appears under a stationary cursor and no mouseEntered is emitted.
        refreshFloatingSidebarPointerState()
        if isPointerInsideFloatingSidebar {
            cancelFloatingSidebarHide()
        }

        if !reduceMotion {
            floatingSidebarLeadingConstraint?.update(offset: 0)
            springFloatingSidebarIntoPlace(panel)
        }
    }

    func hideFloatingSidebar(animated: Bool) {
        // A dock or undock hand-off drops the pointer's slide-out; the
        // hand-off's finish applies the hover rules again.
        if animated, sidebarHandOff != nil { return }
        cancelFloatingSidebarHide()
        guard let panel = floatingSidebarContainerView else { return }
        guard panel.isHidden == false else { return }
        panel.layer?.removeAnimation(forKey: Self.floatingSidebarSlideInAnimationKey)
        returnKeyboardToFullscreenPage(from: panel)
        floatingSidebarViewController?.setMediaPresented(false)
        // A forced hide (sidebar expanding, window ordering out) takes the
        // create-Space form down with the panel; without this the form's
        // `isCreatingSpace` pin on the slot would outlive the visible form.
        // Pointer-driven hides are already blocked while the form is up
        // (see scheduleFloatingSidebarHide), so this only fires on forced paths.
        floatingSidebarViewController?.dismissCreateSpaceOverlay()
        // Likewise any popover the panel pinned itself open for: left up,
        // it would float over the page with its anchor gone.
        let popovers = panelPopovers.allObjects
        panelPopovers.removeAllObjects()
        popovers.forEach { $0.close() }
        let previews = panelFolderPreviews.allObjects
        panelFolderPreviews.removeAllObjects()
        previews.forEach { $0.invalidate() }
        visibilityGeneration += 1
        let generation = visibilityGeneration
        floatingSidebarLeadingConstraint?.update(offset: floatingSidebarHiddenLeading)
        let shouldAnimate = animated && !prefersReducedMotion()
        isFloatingSidebarHideAnimating = shouldAnimate
        pointerTouchedFloatingSidebar = false
        pointerEnteredWindowThroughStrip = false

        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.floatingSidebarHideDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                context.allowsImplicitAnimation = true
                self.view.layoutSubtreeIfNeeded()
            } completionHandler: {
                guard self.visibilityGeneration == generation else { return }
                self.isFloatingSidebarHideAnimating = false
                panel.isHidden = true
                self.floatingSidebarLastShownAt = nil
            }
        } else {
            view.layoutSubtreeIfNeeded()
            panel.isHidden = true
            floatingSidebarLastShownAt = nil
        }
    }

    /// A click in the panel over a fullscreen page takes the keyboard from
    /// the page, and Esc leaves fullscreen only through the page. Hand it
    /// back as the panel goes, as the page container does when the extension
    /// side panel closes, and like it one turn later: a forced hide can run
    /// inside Chromium's synchronous bridge push or a window's teardown.
    /// The window holds the keyboard meanwhile: left in the panel, hiding the
    /// panel would pass it to the next valid key view elsewhere in the window.
    private func returnKeyboardToFullscreenPage(from panel: NSView) {
        guard browserState?.focusingTab?.isInContentFullscreen == true,
              let window = view.window,
              let responder = window.firstResponder as? NSView,
              responder.isDescendant(of: panel),
              window.makeFirstResponder(nil) else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            // Whatever took the keyboard since, the panel shown again
            // included, keeps it.
            guard let self, let window, let state = self.browserState,
                  state.focusingTab?.isInContentFullscreen == true else { return }
            let current = window.firstResponder
            guard current == nil || current === window else { return }
            state.windowController?.mainSplitViewController.webContentContainerViewController.focusWebContent()
        }
    }

    func scheduleFloatingSidebarHide() {
        cancelFloatingSidebarHide()
        // A resize drag can outrun the panel's edge; the panel waits for the
        // drag to end (`endFloatingSidebarResize` schedules again).
        guard !isSwitchingSpace, !isResizingFloatingSidebar else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // The inline create-Space form pins the panel open: a pointer
            // excursion outside the panel must not tear the form down
            // mid-input. The pin lifts when the form closes (its dismiss
            // re-runs this scheduling). A popover or folder preview from the
            // panel pins it the same way (`panelPopovers`).
            guard !isSwitchingSpace,
                  floatingSidebarViewController?.hasCreateSpaceOverlay != true,
                  !hasPanelOverlay else { return }
            refreshFloatingSidebarPointerState()
            guard isPointerInsideFloatingSidebar == false else { return }
            guard isPointerInsideFloatingSidebarTrigger == false else { return }
            // A pointer that ran on out of the window from the panel keeps it
            // open wherever it goes outside. The panel looks again until the
            // pointer is back, and then hides over the page.
            if pointerReachedFloatingSidebar, let window = view.window, let location = pointerLocationInWindow(),
               !NSRect(origin: .zero, size: window.frame.size).contains(location) {
                scheduleFloatingSidebarHide()
                return
            }
            // Slipping just past the inner edge is forgiven: the panel waits
            // while the pointer is in the buffer, checking again as long as
            // it stays there, and closes only once it has moved on.
            if let location = pointerLocationInWindow(), floatingSidebarEdgeBufferContains(location) {
                scheduleFloatingSidebarHide()
                return
            }
            hideFloatingSidebar(animated: true)
        }
        floatingSidebarHideWorkItem = workItem
        let minimumVisibleRemaining: TimeInterval
        if let shownAt = floatingSidebarLastShownAt {
            let visibleElapsed = Date().timeIntervalSince(shownAt)
            minimumVisibleRemaining = max(0, Self.floatingSidebarMinimumVisibleDuration - visibleElapsed)
        } else {
            minimumVisibleRemaining = 0
        }
        let delay = max(Self.floatingSidebarHideDelay, minimumVisibleRemaining)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func cancelFloatingSidebarHide() {
        floatingSidebarHideWorkItem?.cancel()
        floatingSidebarHideWorkItem = nil
    }

    func refreshFloatingSidebarPointerState() {
        if let panel = floatingSidebarContainerView, panel.isHidden == false {
            isPointerInsideFloatingSidebar = isMouseInsideFloatingSidebarVisibleRegion()
        } else {
            isPointerInsideFloatingSidebar = false
        }
        if floatingSidebarTriggerView.isHidden == false {
            isPointerInsideFloatingSidebarTrigger = isMouseInside(view: floatingSidebarTriggerView)
        } else {
            isPointerInsideFloatingSidebarTrigger = false
        }
    }

    func isMouseInside(view targetView: NSView) -> Bool {
        guard targetView.window != nil, let mouseLocationInWindow = pointerLocationInWindow() else { return false }
        let locationInView = targetView.convert(mouseLocationInWindow, from: nil)
        return targetView.bounds.contains(locationInView)
    }

    func isMouseInsideFloatingSidebarVisibleRegion() -> Bool {
        guard let location = pointerLocationInWindow() else { return false }
        return isInsideFloatingSidebarVisibleRegion(location)
    }

    func isInsideFloatingSidebarVisibleRegion(_ mouseLocationInWindow: NSPoint) -> Bool {
        guard let panel = floatingSidebarContainerView, panel.isHidden == false else { return false }
        let panelFrameInWindow = panel.convert(panel.bounds, to: nil)

        let visiblePanelMinX = panelFrameInWindow.minX + Self.floatingSidebarInset
        let withinY = (mouseLocationInWindow.y >= panelFrameInWindow.minY) && (mouseLocationInWindow.y <= panelFrameInWindow.maxY)
        let withinX = sidebarOnRight
            ? mouseLocationInWindow.x >= panelFrameInWindow.minX && mouseLocationInWindow.x <= panelFrameInWindow.maxX - Self.floatingSidebarInset
            : (mouseLocationInWindow.x >= visiblePanelMinX) && (mouseLocationInWindow.x <= panelFrameInWindow.maxX)
        return withinX && withinY
    }

    /// Whether `pointInWindow` lies in the strip just past the open panel's
    /// inner edge, where the pointer can slip off without closing it.
    func floatingSidebarEdgeBufferContains(_ pointInWindow: NSPoint) -> Bool {
        guard let panel = floatingSidebarContainerView, panel.isHidden == false else { return false }
        return Self.edgeBuffer(of: panel.convert(panel.bounds, to: nil), sidebarOnRight: sidebarOnRight,
                               contains: pointInWindow)
    }

    /// Whether `point` lies in the strip just past the inner edge of a panel
    /// at `panelFrame`: right of it with the sidebar on the left, left of it
    /// with the sidebar on the right.
    static func edgeBuffer(of panelFrame: NSRect, sidebarOnRight: Bool, contains point: NSPoint) -> Bool {
        let withinY = point.y >= panelFrame.minY && point.y <= panelFrame.maxY
        let withinX = sidebarOnRight
            ? point.x < panelFrame.minX && point.x >= panelFrame.minX - floatingSidebarEdgeBufferWidth
            : point.x > panelFrame.maxX && point.x <= panelFrame.maxX + floatingSidebarEdgeBufferWidth
        return withinX && withinY
    }

    /// The panel's width after its inner edge has been dragged `dragOffset`
    /// points to the right from where it was at `startWidth`. With the
    /// sidebar on the right the inner edge is the panel's left edge, so
    /// dragging left widens it.
    static func floatingSidebarWidth(from startWidth: CGFloat, dragOffset: CGFloat, sidebarOnRight: Bool) -> CGFloat {
        startWidth + (sidebarOnRight ? -dragOffset : dragOffset)
    }

    /// The ways the inner edge of a panel `width` wide can still move, as the
    /// docked column's divider shows them: at the widest only inward, at the
    /// narrowest only outward. Inward is left with the sidebar on the left,
    /// right with the sidebar on the right.
    static func floatingSidebarResizeDirections(forWidth width: CGFloat, sidebarOnRight: Bool)
        -> FloatingSidebarResizeHandleView.Directions {
        if width >= MainSplitViewController.leftItemMaxWidth {
            return sidebarOnRight ? .rightOnly : .leftOnly
        }
        if width <= MainSplitViewController.leftItemMinWidth {
            return sidebarOnRight ? .leftOnly : .rightOnly
        }
        return .both
    }
}

final class MouseTrackingAreaView: NSView {
    var onMouseEntered: ((NSEvent) -> Void)?
    var onMouseExited: ((NSEvent) -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let newTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newTrackingArea)
        trackingArea = newTrackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onMouseEntered?(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseExited?(event)
    }
}

/// The strip along the floating panel's inner edge. Dragging it resizes the
/// panel, as dragging the divider resizes the docked column
/// (`ShellSplitDividerView`).
class FloatingSidebarResizeHandleView: NSView {
    var onBegin: (() -> Void)?
    /// The pointer's horizontal distance from where the drag started.
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    /// The ways the edge can move right now, read for the cursor.
    var directions: (() -> Directions)?

    enum Directions {
        case both, leftOnly, rightOnly
    }

    private var dragStartX: CGFloat?
    private var cursorTrackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        // A tracking area rather than a cursor rect: the page under the panel
        // sets its own cursor, and only `cursorUpdate` wins over it.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        updateCursor()
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX else { return }
        onDrag?(event.locationInWindow.x - dragStartX)
        // After the drag, so a drag that reaches a limit shows it at once.
        updateCursor()
    }

    /// Shows the cursor the docked column's divider shows for the same
    /// width: a one-way arrow once the edge can move only one way.
    private func updateCursor() {
        let directions = directions?() ?? .both
        if #available(macOS 15.0, *) {
            switch directions {
            case .both: NSCursor.columnResize.set()
            case .leftOnly: NSCursor.columnResize(directions: .left).set()
            case .rightOnly: NSCursor.columnResize(directions: .right).set()
            }
        } else {
            switch directions {
            case .both: NSCursor.resizeLeftRight.set()
            case .leftOnly: NSCursor.resizeLeft.set()
            case .rightOnly: NSCursor.resizeRight.set()
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartX != nil else { return }
        dragStartX = nil
        onEnd?()
    }
}

/// The full-page overlay accepts hits only on the trigger and visible panel.
/// Everything else remains available to the page and its own overlays. Over
/// a fullscreen page the trigger strip and the panel's container only track
/// the pointer, through their tracking areas, and their clicks (the strip,
/// the inset left of the glass) reach the page too.
final class FloatingSidebarOverlayView: NSView {
    var isOverFullscreenPage: () -> Bool = { false }
    /// The pointer crossing the window's edge, which the strip and the panel
    /// miss when a fast pointer goes around or past them.
    var onPointerEnteredWindow: ((NSEvent) -> Void)?
    var onPointerLeftWindow: ((NSEvent) -> Void)?
    private var windowEdgeTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let windowEdgeTrackingArea { removeTrackingArea(windowEdgeTrackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        windowEdgeTrackingArea = area
    }

    // The strip's and the panel's own entries and exits pass up the
    // responder chain to here; only the window's edge counts.
    override func mouseEntered(with event: NSEvent) {
        guard let area = windowEdgeTrackingArea, event.trackingArea === area else { return super.mouseEntered(with: event) }
        onPointerEnteredWindow?(event)
    }

    override func mouseExited(with event: NSEvent) {
        guard let area = windowEdgeTrackingArea, event.trackingArea === area else { return super.mouseExited(with: event) }
        onPointerLeftWindow?(event)
    }

    /// The panel while it shows; see `mouseDown(with:)`.
    var visiblePanel: () -> NSView? = { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self { return nil }
        if hit is MouseTrackingAreaView, isOverFullscreenPage() { return nil }
        return hit
    }

    /// A click on the panel that nothing in it handles, such as one on the
    /// header beside the sidebar button, comes up the panel's responder chain
    /// to here. Passed on, AppKit handed it to the page header under the
    /// panel, and the address bar opened. It ends on the panel instead; a
    /// click elsewhere passes on as before.
    override func mouseDown(with event: NSEvent) {
        guard !isOnVisiblePanel(event) else { return }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isOnVisiblePanel(event) else { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard !isOnVisiblePanel(event) else { return }
        super.mouseUp(with: event)
    }

    private func isOnVisiblePanel(_ event: NSEvent) -> Bool {
        guard let panel = visiblePanel(), panel.window === event.window else { return false }
        return panel.bounds.contains(panel.convert(event.locationInWindow, from: nil))
    }
}
