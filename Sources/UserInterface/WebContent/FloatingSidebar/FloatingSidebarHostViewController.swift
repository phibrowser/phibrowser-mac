// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit

/// Owns the hover panel, trigger and dismissal lifetime for one window.
/// Hosted Spaces replace its content; their page trees never own the panel.
final class FloatingSidebarHostViewController: NSViewController {
    private(set) weak var browserState: BrowserState?
    private var subscriptions = Set<AnyCancellable>()
    private let floatingSidebarTriggerView = MouseTrackingAreaView()
    private(set) var floatingSidebarContainerView: NSView?
    private(set) var floatingSidebarViewController: FloatingSidebarViewController?
    private var outgoingContent: FloatingSidebarViewController?
    private var panelContentView: NSView?
    private var floatingSidebarLeadingConstraint: Constraint?
    private var floatingSidebarWidthConstraint: Constraint?
    private var floatingSidebarHideWorkItem: DispatchWorkItem?
    private var floatingSidebarEnableWorkItem: DispatchWorkItem?
    private var floatingSidebarWidthSyncWorkItem: DispatchWorkItem?
    private var floatingSidebarLastShownAt: Date?
    private var floatingSidebarShownFromRightToLeft = false
    private var floatingSidebarOcclusionObserver: NSObjectProtocol?
    private var isPointerInsideFloatingSidebar = false
    private var isPointerInsideFloatingSidebarTrigger = false
    private var isSwitchingSpace = false
    private var visibilityGeneration = 0
    /// The presented Space's content was made the panel's while the panel
    /// was hidden, without activation or layout; `installContent` runs
    /// before the panel next shows or is realized off screen.
    private var needsContentInstall = false

    var isVisible: Bool { floatingSidebarContainerView?.isHidden == false }

    override func loadView() { view = FloatingSidebarOverlayView() }

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
    }

    func install(in parent: NSViewController, over content: NSView) {
        parent.addChild(self)
        parent.view.addSubview(view)
        view.snp.makeConstraints { make in make.edges.equalTo(content) }
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

    func beginSpaceSwitch() {
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
    }

    static let floatingSidebarDefaultWidth: CGFloat = MainSplitViewController.leftItemMinWidth
    static let floatingSidebarTriggerWidth: CGFloat = 10
    static let floatingSidebarHideDelay: TimeInterval = 0.12
    static let floatingSidebarMinimumVisibleDuration: TimeInterval = 0.5
    static let floatingSidebarInset: CGFloat = 5
    static let floatingSidebarShowDuration: TimeInterval = 0.15
    static let floatingSidebarHideDuration: TimeInterval = 0.15
    /// Quiet period after the docked column's last width change before the
    /// hidden panel follows it; shorter than the trigger's enable delay after
    /// a collapse, so a deferred sync lands before the panel can first show.
    static let floatingSidebarWidthSyncDelay: TimeInterval = 0.25

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
        -(currentFloatingWidth + Self.floatingSidebarInset)
    }

    func setupFloatingSidebarTrigger() {
        floatingSidebarTriggerView.onMouseEntered = { [weak self] event in
            guard let self else { return }
            isPointerInsideFloatingSidebarTrigger = true
            let enterPoint = floatingSidebarTriggerView.convert(event.locationInWindow, from: nil)
            floatingSidebarShownFromRightToLeft = enterPoint.x >= (Self.floatingSidebarTriggerWidth * 0.5)
            showFloatingSidebar()
        }

        floatingSidebarTriggerView.onMouseExited = { [weak self] _ in
            guard let self else { return }
            isPointerInsideFloatingSidebarTrigger = false
            scheduleFloatingSidebarHide()
        }
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
        let interactionContainerView = MouseTrackingAreaView()
        interactionContainerView.onMouseEntered = { [weak self] _ in
            guard let self else { return }
            refreshFloatingSidebarPointerState()
            if !isPointerInsideFloatingSidebarTrigger && floatingSidebarShownFromRightToLeft {
                floatingSidebarShownFromRightToLeft = false
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

        self.panelContentView = panelContentView

        let panelVisualContainer: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.contentView = panelContentView
            glass.cornerRadius = 14
            glass.style = .regular
            panelVisualContainer = glass
        } else {
            panelVisualContainer = panelContentView
        }

        interactionContainerView.addSubview(panelVisualContainer)
        panelVisualContainer.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(Self.floatingSidebarInset)
            make.top.bottom.trailing.equalToSuperview()
        }

        // Sit above `outerBorderLayer` (zPosition = contentOuterBorder) so the
        // unified content-border stroke doesn't paint on top of the panel
        // when it slides in over the web content.
        interactionContainerView.wantsLayer = true
        interactionContainerView.layer?.zPosition = WebContentContainerViewController.LayerZIndex.floatingSidebar

        view.addSubview(interactionContainerView, positioned: .above, relativeTo: nil)
        interactionContainerView.snp.makeConstraints { make in
            floatingSidebarLeadingConstraint = make.leading.equalToSuperview().offset(floatingSidebarHiddenLeading).constraint
            make.top.equalToSuperview().offset(Self.floatingSidebarInset)
            make.bottom.equalToSuperview().offset(-Self.floatingSidebarInset)
            floatingSidebarWidthConstraint = make.width.equalTo(currentFloatingWidth + Self.floatingSidebarInset).constraint
        }
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

    /// Applies a width sync `updateFloatingSidebarWidth` deferred, if any.
    private func flushPendingFloatingSidebarWidthSync() {
        guard let workItem = floatingSidebarWidthSyncWorkItem else { return }
        workItem.cancel()
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

    func updateFloatingSidebarAvailability() {
        let shouldEnable = shouldEnableFloatingSidebar()

        floatingSidebarEnableWorkItem?.cancel()
        floatingSidebarEnableWorkItem = nil

        if !shouldEnable {
            floatingSidebarTriggerView.isHidden = true
            isPointerInsideFloatingSidebar = false
            isPointerInsideFloatingSidebarTrigger = false
            floatingSidebarShownFromRightToLeft = false
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
        cancelFloatingSidebarHide()

        guard let panel = floatingSidebarContainerView else { return }
        visibilityGeneration += 1
        guard panel.isHidden else {
            floatingSidebarLeadingConstraint?.update(offset: 0)
            view.layoutSubtreeIfNeeded()
            return
        }

        // Ensure panel starts offscreen before sliding in.
        floatingSidebarLeadingConstraint?.update(offset: floatingSidebarHiddenLeading)
        view.layoutSubtreeIfNeeded()
        panel.isHidden = false
        floatingSidebarLastShownAt = Date()
        floatingSidebarViewController?.refreshFloatingTrafficLights()

        // Handle the case where the panel appears under a stationary cursor and no mouseEntered is emitted.
        refreshFloatingSidebarPointerState()
        if isPointerInsideFloatingSidebar {
            cancelFloatingSidebarHide()
        }

        floatingSidebarLeadingConstraint?.update(offset: 0)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.floatingSidebarShowDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            self.view.layoutSubtreeIfNeeded()
        }
    }

    func hideFloatingSidebar(animated: Bool) {
        cancelFloatingSidebarHide()
        guard let panel = floatingSidebarContainerView else { return }
        guard panel.isHidden == false else { return }
        // A forced hide (sidebar expanding, window ordering out) takes the
        // create-Space form down with the panel; without this the form's
        // `isCreatingSpace` pin on the slot would outlive the visible form.
        // Pointer-driven hides are already blocked while the form is up
        // (see scheduleFloatingSidebarHide), so this only fires on forced paths.
        floatingSidebarViewController?.dismissCreateSpaceOverlay()
        visibilityGeneration += 1
        let generation = visibilityGeneration
        floatingSidebarLeadingConstraint?.update(offset: floatingSidebarHiddenLeading)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.floatingSidebarHideDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                context.allowsImplicitAnimation = true
                self.view.layoutSubtreeIfNeeded()
            } completionHandler: {
                guard self.visibilityGeneration == generation else { return }
                panel.isHidden = true
                self.floatingSidebarLastShownAt = nil
                self.floatingSidebarShownFromRightToLeft = false
            }
        } else {
            view.layoutSubtreeIfNeeded()
            panel.isHidden = true
            floatingSidebarLastShownAt = nil
            floatingSidebarShownFromRightToLeft = false
        }
    }

    func scheduleFloatingSidebarHide() {
        cancelFloatingSidebarHide()
        guard !isSwitchingSpace else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // The inline create-Space form pins the panel open: a pointer
            // excursion outside the panel must not tear the form down
            // mid-input. The pin lifts when the form closes (its dismiss
            // re-runs this scheduling).
            guard !isSwitchingSpace,
                  floatingSidebarViewController?.hasCreateSpaceOverlay != true else { return }
            refreshFloatingSidebarPointerState()
            guard isPointerInsideFloatingSidebar == false else { return }
            guard isPointerInsideFloatingSidebarTrigger == false else { return }
            if floatingSidebarShownFromRightToLeft, isMouseAtFloatingSidebarLeftSide() {
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
        guard let window = targetView.window else { return false }
        let mouseLocationInWindow = window.mouseLocationOutsideOfEventStream
        let locationInView = targetView.convert(mouseLocationInWindow, from: nil)
        return targetView.bounds.contains(locationInView)
    }

    func isMouseAtFloatingSidebarLeftSide() -> Bool {
        guard let panel = floatingSidebarContainerView, panel.isHidden == false else { return false }
        guard let window = panel.window else { return false }
        let mouseLocationInWindow = window.mouseLocationOutsideOfEventStream
        let panelFrameInWindow = panel.convert(panel.bounds, to: nil)

        let withinY = (mouseLocationInWindow.y >= panelFrameInWindow.minY) && (mouseLocationInWindow.y <= panelFrameInWindow.maxY)
        let visiblePanelMinX = panelFrameInWindow.minX + Self.floatingSidebarInset
        return withinY && mouseLocationInWindow.x < visiblePanelMinX
    }

    func isMouseInsideFloatingSidebarVisibleRegion() -> Bool {
        guard let panel = floatingSidebarContainerView, panel.isHidden == false else { return false }
        guard let window = panel.window else { return false }
        let mouseLocationInWindow = window.mouseLocationOutsideOfEventStream
        let panelFrameInWindow = panel.convert(panel.bounds, to: nil)

        let visiblePanelMinX = panelFrameInWindow.minX + Self.floatingSidebarInset
        let withinY = (mouseLocationInWindow.y >= panelFrameInWindow.minY) && (mouseLocationInWindow.y <= panelFrameInWindow.maxY)
        let withinX = (mouseLocationInWindow.x >= visiblePanelMinX) && (mouseLocationInWindow.x <= panelFrameInWindow.maxX)
        return withinX && withinY
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

/// The full-page overlay accepts hits only on the trigger and visible panel.
/// Everything else remains available to the page and its own overlays.
private final class FloatingSidebarOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
