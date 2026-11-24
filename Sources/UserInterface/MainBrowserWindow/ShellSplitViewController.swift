// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine

/// The shell window's one split: the sidebar column and the page area. It belongs to the window, not to any Space session,
/// which is what makes the sidebar read as one sidebar across Space
/// switches: its width, collapsed state, vibrancy backdrop and divider never
/// rebuild when the presented session changes. A session contributes two
/// views — its sidebar content (`SidebarViewController.view`, painting no
/// backdrop of its own) into `sidebarHost`, and its page tree
/// (`MainSplitViewController.view`) into `contentHost` — and the
/// vertical-layout switch slides the sidebar band inside the column while
/// the page area swaps underneath (`SpaceWindowSlot.HostedBandSlide`).
///
/// This controller is the sole owner of sidebar geometry: the width the
/// user chose for each side, the collapsed state and the toggle in flight.
/// `ShellSplitView` places the views from it. Sessions observe it through
/// read-only publishers; presenting or creating a Space never writes width
/// or collapsed state back into the shell.
/// See docs/architecture/custom-shell-split.md.
final class ShellSplitViewController: NSViewController {
    static let leftItemMinWidth = MainSplitViewController.leftItemMinWidth
    static let leftItemMaxWidth = MainSplitViewController.leftItemMaxWidth
    let splitView = ShellSplitView()
    let sidebarHost = ShellSidebarHostViewController()
    let contentHost = ShellContentHostViewController()
    let floatingSidebarHost = FloatingSidebarHostViewController()
    private var cancellables = Set<AnyCancellable>()
    private var lastTraditionalLayout: Bool?

    private var sidebarOnRight = false
    private var side: SidebarPosition { sidebarOnRight ? .right : .left }
    private var transitions = SidebarTransitions(isCollapsed: false)
    private var flightCompletions: [Int: (Bool) -> Void] = [:]
    /// The width the user chose for the column on each side. A side with
    /// none opens at the minimum.
    private var preferredWidths: [SidebarPosition: CGFloat] = [:]
    private var dividerDrag: DividerDrag?
    private let collapsedSubject = CurrentValueSubject<Bool, Never>(false)
    private let widthSubject = CurrentValueSubject<CGFloat, Never>(0)
    private let takesPageSpaceSubject = CurrentValueSubject<Bool, Never>(true)

    /// An animated expansion has landed. A superseded one never reports.
    let sidebarExpansionDidFinish = PassthroughSubject<Void, Never>()
    /// An animated expansion has started and not landed. The collapsed state
    /// changes as soon as it starts.
    var isSidebarExpanding: Bool { transitions.isExpanding }

    /// The account's defaults, where each side's width is kept. A test seam.
    lazy var accountDefaults: () -> AccountUserDefaults? = {
        AccountController.shared.localDataAccount?.userDefaults
    }

    private var isTraditionalLayout: Bool {
        PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
    }

    /// The root view's width, which the window sets at once; the split view
    /// fills it, but only takes its frame in the next layout pass.
    private var containerWidth: CGFloat { view.bounds.width }

    private var preferredWidth: CGFloat {
        ShellSplitGeometry.clampedToLimits(preferredWidths[side] ?? Self.leftItemMinWidth)
    }

    override func loadView() {
        view = TitlebarTransparentView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(sidebarHost)
        addChild(contentHost)
        splitView.install(column: sidebarHost.view, page: contentHost.view)
        view.addSubview(splitView)
        splitView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        sidebarOnRight = SidebarPosition.isOnRight
        loadStoredGeometry()
        connectDivider()
        splitView.onWidthChange = { [weak self] in self?.containerWidthDidChange() }
        splitView.pageCard = { [weak self] in self?.contentHost.slidingPageCard }
        splitView.onPageInsetInFlight = { [weak self] inset in self?.contentHost.setPageInsetInFlight(inset) }
        applyState()

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateLayoutForHorizontalTabs() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.persistGeometry() }
            .store(in: &cancellables)
        // The window's own transition takes over its content; the toggle
        // lands first.
        NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification))
            .filter { [weak self] in ($0.object as? NSWindow) === self?.view.window }
            .sink { [weak self] _ in self?.settleTransition() }
            .store(in: &cancellables)
        updateLayoutForHorizontalTabs()
        floatingSidebarHost.install(in: self)
        contentHost.view.postsFrameChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: contentHost.view)
            .sink { [weak self] _ in self?.scheduleToastOverlayInsetsUpdate() }
            .store(in: &cancellables)
    }

    /// The window's one toast overlay, over the split and below the floating
    /// panel, showing the presented Space's toasts. It keeps the window's
    /// size, so a column animation never lays it out; it takes the page
    /// area's insets once the column has settled.
    private var toastOverlay: OverlayToastViewController?
    private var toastOverlayInsetsWorkItem: DispatchWorkItem?
    /// Quiet period after the page area's last frame change before the
    /// overlay takes its insets.
    private static let toastOverlayInsetsDelay: TimeInterval = 0.15

    func presentToastOverlay(for state: BrowserState) {
        if let toastOverlay {
            toastOverlay.present(state)
            return
        }
        let overlay = OverlayToastViewController(state: state)
        addChild(overlay)
        view.addSubview(overlay.view, positioned: .below, relativeTo: floatingSidebarHost.view)
        overlay.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            overlay.view.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        toastOverlay = overlay
        updateToastOverlayInsets()
    }

    private func scheduleToastOverlayInsetsUpdate() {
        guard toastOverlay != nil else { return }
        toastOverlayInsetsWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.toastOverlayInsetsWorkItem = nil
            self?.updateToastOverlayInsets()
        }
        toastOverlayInsetsWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toastOverlayInsetsDelay, execute: workItem)
    }

    private func updateToastOverlayInsets() {
        guard let toastOverlay else { return }
        let pageArea = contentHost.view.convert(contentHost.view.bounds, to: view)
        toastOverlay.setContentInsets(NSEdgeInsets(
            top: 0, left: pageArea.minX, bottom: 0, right: view.bounds.width - pageArea.maxX))
    }

    /// The collapsed state as last asked for: it changes when a toggle
    /// starts, once per toggle.
    var sidebarCollapsedPublisher: AnyPublisher<Bool, Never> {
        collapsedSubject.removeDuplicates().eraseToAnyPublisher()
    }

    /// The column's width, 0 while collapsed: one value per toggle and per
    /// step of a divider drag, none per animation frame.
    var sidebarWidthPublisher: AnyPublisher<CGFloat, Never> {
        widthSubject.removeDuplicates().eraseToAnyPublisher()
    }

    /// Whether the column takes its width from the page area: false while
    /// collapsed and for the whole of a toggle in flight. It changes with the
    /// page area's frame, in the same turn: when a collapse starts and when
    /// an expansion lands. The page's sidebar-side inset follows this, so a
    /// toggle lays the page out once.
    var sidebarTakesPageSpacePublisher: AnyPublisher<Bool, Never> {
        takesPageSpaceSubject.removeDuplicates().eraseToAnyPublisher()
    }

    var sidebarTakesPageSpace: Bool { transitions.columnTakesPageSpace }

    var isSidebarCollapsed: Bool { transitions.isCollapsed }

    var sidebarWidth: CGFloat {
        guard isViewLoaded, !transitions.isCollapsed else { return 0 }
        return splitView.geometry.effectiveWidth(inContainerOfWidth: containerWidth)
    }

    func toggleSidebar(_ collapsed: Bool? = nil) {
        setSidebarCollapsed(collapsed ?? !isSidebarCollapsed, animated: true)
    }

    /// `completion` is called exactly once: with true when the column got
    /// to `collapsed`, at once if it is there already, and with false when a
    /// later request for the other state cut this one short.
    func setSidebarCollapsed(_ collapsed: Bool, animated: Bool, completion: ((_ finished: Bool) -> Void)? = nil) {
        // A toggle during a hand-off starts from the hand-off's end state.
        floatingSidebarHost.finishSidebarHandOffImmediately()
        sidebarHost.setResidentsHidden(false)
        let target = isTraditionalLayout || collapsed
        let shouldAnimate = animated && !floatingSidebarHost.prefersReducedMotion()
        if animated, transitions.isCollapsed != target,
           handOffSidebar(collapsing: target, animated: shouldAnimate, completion: completion) {
            return
        }
        changeCollapsed(to: target, duration: shouldAnimate ? SidebarToggleAnimation.duration : nil,
                        completion: completion)
    }

    /// Aligns the column to `width` / `collapsed`. The column persists across
    /// Spaces, so this only matters when a caller wants a shape other than
    /// the one on screen.
    func setSidebarGeometry(width: CGFloat?, collapsed: Bool) {
        guard !isTraditionalLayout else { return }
        if !collapsed, let width, width > 0 {
            setPreferredWidth(width)
        }
        setSidebarCollapsed(collapsed, animated: false)
        applyState()
    }

    func containsSidebarTabDragBoundary(at screenLocation: CGPoint) -> Bool {
        guard !transitions.isCollapsed else { return false }
        return sidebarHost.view.containsScreenLocation(screenLocation)
    }

    private func updateSidebarPosition() {
        let right = SidebarPosition.isOnRight
        guard sidebarOnRight != right else { return }
        settleTransition()
        dividerDrag = nil
        let width = preferredWidth
        sidebarOnRight = right
        // A side that never had a width of its own takes the other's along.
        if preferredWidths[side] == nil {
            setPreferredWidth(width)
        }
        applyState()
    }

    private func updateLayoutForHorizontalTabs() {
        updateSidebarPosition()
        let traditional = isTraditionalLayout
        if let last = lastTraditionalLayout, last == traditional { return }
        let changingLayout = lastTraditionalLayout != nil
        lastTraditionalLayout = traditional
        if traditional || changingLayout {
            setSidebarCollapsed(traditional, animated: false)
        }
    }

    /// The width the column opens at in this window: the floating panel's
    /// width while the column is collapsed. 0 before the view is loaded.
    var lastExpandedSidebarWidth: CGFloat {
        guard isViewLoaded else { return 0 }
        return ShellSplitGeometry.effectiveWidth(preferred: preferredWidth, inContainerOfWidth: containerWidth)
    }

    /// Takes the floating panel's width, resized by the user while the column
    /// is collapsed, as the column's width: the panel opens at it from now on
    /// and the column docks at it.
    func adoptFloatingSidebarWidth(_ width: CGFloat) {
        guard transitions.isCollapsed else { return }
        setPreferredWidth(min(width, ShellSplitGeometry.maxWidth(inContainerOfWidth: containerWidth)))
        applyState()
    }

    /// Brings the views and the publishers in line with the state.
    private func applyState() {
        var geometry = splitView.geometry
        geometry.sidebarOnRight = sidebarOnRight
        geometry.preferredWidth = dividerDrag?.width ?? preferredWidth
        geometry.columnTakesPageSpace = transitions.columnTakesPageSpace
        splitView.geometry = geometry
        splitView.isColumnHidden = transitions.isCollapsed && transitions.flight == nil
        // No divider on a collapsed edge or under a column in flight; one
        // that collapsed the column mid-drag keeps the drag.
        splitView.divider.isHidden = !transitions.columnTakesPageSpace && dividerDrag == nil
        collapsedSubject.send(transitions.isCollapsed)
        widthSubject.send(sidebarWidth)
        takesPageSpaceSubject.send(transitions.columnTakesPageSpace)
    }

    /// The one way the collapsed state changes. `duration` is a whole
    /// toggle's, nil for a change that applies at once.
    private func changeCollapsed(to collapsed: Bool, duration: TimeInterval?, widensWindow: Bool = true,
                                 completion: ((Bool) -> Void)? = nil) {
        if !collapsed, transitions.isCollapsed, widensWindow {
            widenWindowForColumnIfNeeded()
        }
        let outcome = transitions.request(collapsed: collapsed, duration: duration,
                                          shownFraction: splitView.shownColumnFraction)
        if let ended = outcome.ended {
            finish(ended, finished: outcome.endedAtItsTarget)
        }
        guard outcome.changed else {
            completion?(true)
            return
        }
        // The comfortable layout's forced collapse is not the user's.
        if !isTraditionalLayout {
            collapsedToStore = collapsed
            schedulePersist()
        }
        applyState()
        guard let flight = outcome.flight else {
            completion?(true)
            return
        }
        flightCompletions[flight.id] = completion
        contentHost.setPageBackdropPaintsPageBackground(true)
        splitView.slideColumn(for: flight) { [weak self] in
            self?.land(flight.id)
        }
    }

    private func land(_ id: Int) {
        guard let flight = transitions.land(id) else { return }
        finish(flight, finished: true)
    }

    /// Lands the toggle in flight now: a change that is not a toggle (a
    /// width, the side, the window's size) starts from a settled column.
    private func settleTransition() {
        guard let flight = transitions.settle() else { return }
        finish(flight, finished: true)
    }

    private func finish(_ flight: SidebarTransitions.Flight, finished: Bool) {
        let completion = flightCompletions.removeValue(forKey: flight.id)
        // With the frames' next state, in this turn: the end state when the
        // flight landed, the next flight's slide when it was cut short.
        splitView.endSlide()
        contentHost.setPageBackdropPaintsPageBackground(false)
        if finished {
            applyState()
            if !flight.collapsing {
                sidebarExpansionDidFinish.send()
            }
            if hasGeometryToStore {
                schedulePersist()
            }
        }
        completion?(finished)
    }

    /// Where the page cannot give the column its width, opening the column
    /// widens the window by it, as the NSSplitView this replaced did.
    private func widenWindowForColumnIfNeeded() {
        guard let window = view.window, !window.styleMask.contains(.fullScreen) else { return }
        let columnWidth = preferredWidth
        guard containerWidth > 0, containerWidth - columnWidth < ShellSplitGeometry.pageMinWidth else { return }
        var frame = window.frame
        frame.size.width += columnWidth
        window.setFrame(frame, display: true)
        // The split view takes the new width before the toggle starts.
        view.layoutSubtreeIfNeeded()
    }

    private func containerWidthDidChange() {
        settleTransition()
        widthSubject.send(sidebarWidth)
    }

    private func setPreferredWidth(_ width: CGFloat) {
        let clamped = ShellSplitGeometry.clampedToLimits(width).rounded()
        guard preferredWidths[side] != clamped else { return }
        preferredWidths[side] = clamped
        widthsToStore.insert(side)
        schedulePersist()
    }

    private struct DividerDrag {
        let startWidth: CGFloat
        /// The width the drag has the column at; nil while it has it
        /// collapsed.
        var width: CGFloat?
    }

    private func connectDivider() {
        let divider = splitView.divider
        divider.onBegin = { [weak self] in self?.beginDividerDrag() }
        divider.onDrag = { [weak self] offset in self?.continueDividerDrag(offset: offset) }
        divider.onEnd = { [weak self] in self?.endDividerDrag() }
        divider.directions = { [weak self] in self?.dividerDirections ?? .both }
        divider.range = { [weak self] in
            self?.dividerRange ?? ShellSplitDividerView.Range(position: 0, min: 0, max: 0)
        }
        divider.onAccessibilityStep = { [weak self] towardMax in self?.stepDivider(towardMax: towardMax) }
    }

    private func beginDividerDrag() {
        guard !transitions.isCollapsed else { return }
        settleTransition()
        let width = sidebarWidth
        dividerDrag = DividerDrag(startWidth: width, width: width)
    }

    /// The drag is live. Past half the minimum width it collapses the
    /// column, and reopens it on the way back.
    private func continueDividerDrag(offset: CGFloat) {
        guard var drag = dividerDrag else { return }
        let proposed = drag.startWidth + (sidebarOnRight ? -offset : offset)
        if proposed < Self.leftItemMinWidth / 2 {
            drag.width = nil
            dividerDrag = drag
            changeCollapsed(to: true, duration: nil)
            return
        }
        drag.width = min(max(proposed, Self.leftItemMinWidth),
                         ShellSplitGeometry.maxWidth(inContainerOfWidth: containerWidth))
        dividerDrag = drag
        if transitions.isCollapsed {
            changeCollapsed(to: false, duration: nil, widensWindow: false)
        } else {
            applyState()
        }
    }

    /// The width the drag ends on is the user's from then on. A drag that
    /// ends collapsed leaves it as it was.
    private func endDividerDrag() {
        guard let drag = dividerDrag else { return }
        dividerDrag = nil
        if let width = drag.width {
            setPreferredWidth(width)
        }
        applyState()
    }

    private var dividerDirections: FloatingSidebarResizeHandleView.Directions {
        let width = sidebarWidth
        if width >= ShellSplitGeometry.maxWidth(inContainerOfWidth: containerWidth) {
            return sidebarOnRight ? .rightOnly : .leftOnly
        }
        if width <= Self.leftItemMinWidth {
            return sidebarOnRight ? .leftOnly : .rightOnly
        }
        return .both
    }

    private var dividerRange: ShellSplitDividerView.Range {
        let size = splitView.bounds.size
        let narrowest = Self.leftItemMinWidth
        let widest = ShellSplitGeometry.maxWidth(inContainerOfWidth: size.width)
        return ShellSplitDividerView.Range(
            position: splitView.geometry.dividerPosition(in: size),
            min: sidebarOnRight ? size.width - widest : narrowest,
            max: sidebarOnRight ? size.width - narrowest : widest)
    }

    private static let accessibilityDividerStep: CGFloat = 10

    private func stepDivider(towardMax: Bool) {
        guard !transitions.isCollapsed else { return }
        settleTransition()
        let widening = towardMax != sidebarOnRight
        let width = sidebarWidth + (widening ? Self.accessibilityDividerStep : -Self.accessibilityDividerStep)
        setPreferredWidth(min(max(width, Self.leftItemMinWidth),
                              ShellSplitGeometry.maxWidth(inContainerOfWidth: containerWidth)))
        applyState()
    }

    private var widthsToStore = Set<SidebarPosition>()
    /// The collapsed state the user left the column in, not yet written.
    private var collapsedToStore: Bool?
    private var persistWorkItem: DispatchWorkItem?
    /// Quiet period after the last change before the geometry is written.
    private static let geometryPersistDelay: TimeInterval = 0.3

    private var hasGeometryToStore: Bool {
        !widthsToStore.isEmpty || collapsedToStore != nil
    }

    /// Reads each side's width from the account and the collapsed state
    /// from the app's defaults.
    private func loadStoredGeometry() {
        let defaults = accountDefaults()
        for side in SidebarPosition.allCases {
            let width = defaults?.lastKnownSidebarWidth(for: side) ?? 0
            if width >= Self.leftItemMinWidth {
                preferredWidths[side] = ShellSplitGeometry.clampedToLimits(width)
            }
        }
        let traditional = isTraditionalLayout
        let collapsed: Bool
        if let stored = PhiPreferences.GeneralSettings.loadSidebarCollapsed() {
            collapsed = stored
        } else {
            collapsed = migrateAutosavedColumn(trustingCollapsed: !traditional)
            PhiPreferences.GeneralSettings.saveSidebarCollapsed(collapsed)
        }
        transitions = SidebarTransitions(isCollapsed: traditional || collapsed)
    }

    /// Takes over what the shell's NSSplitView autosaved for this side, the
    /// one time there is no collapsed state of the shell's own: the column's
    /// width as this side's, and whether it was collapsed, which is returned.
    /// In the comfortable layout the saved column is collapsed by the layout,
    /// not by the user, so that is not taken.
    ///
    /// The saved frames stay where they are: standalone windows still save
    /// under the same names.
    private func migrateAutosavedColumn(trustingCollapsed: Bool) -> Bool {
        let name = sidebarOnRight ? "phiMainBrowserSplitViewRight" : "phiMainBrowserSplitView"
        guard let frames = UserDefaults.standard.stringArray(forKey: "NSSplitView Subview Frames \(name)"),
              let column = Self.autosavedColumn(in: frames, sidebarOnRight: sidebarOnRight) else { return false }
        if (Self.leftItemMinWidth...Self.leftItemMaxWidth).contains(column.width) {
            setPreferredWidth(column.width)
        }
        AppLogInfo("[ShellSplit] migrated autosaved column: width=\(column.width) collapsed=\(column.collapsed)")
        return trustingCollapsed && column.collapsed
    }

    /// NSSplitView saves one string per subview, "x, y, width, height,
    /// hidden, …", in subview order: the column is first on the left and
    /// second on the right.
    static func autosavedColumn(in frames: [String], sidebarOnRight: Bool) -> (width: CGFloat, collapsed: Bool)? {
        guard frames.count == 2 else { return nil }
        let fields = frames[sidebarOnRight ? 1 : 0].components(separatedBy: ", ")
        guard fields.count >= 5, let width = Double(fields[2]) else { return nil }
        return (CGFloat(width), fields[4] == "YES")
    }

    /// Writes the geometry once it has been still for
    /// `geometryPersistDelay`: a divider drag reports a width on every frame
    /// and a burst of toggles a state each, each account-defaults write
    /// rewrites the whole store, and a write to the app's defaults notifies
    /// every Space's observers.
    private func schedulePersist() {
        persistWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            persistWorkItem = nil
            // Not under a toggle in flight; landing schedules this again.
            guard transitions.flight == nil else { return }
            persistGeometry()
        }
        persistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.geometryPersistDelay, execute: workItem)
    }

    /// The shell window is closing for good. What is waiting to be stored
    /// is written now, and the split stops following the app's defaults: a
    /// closed window's column must not answer a later layout or side change
    /// and store over the open windows' state.
    func windowWillClose() {
        persistGeometry()
        cancellables.removeAll()
    }

    private func persistGeometry() {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        if let defaults = accountDefaults() {
            for side in widthsToStore {
                if let width = preferredWidths[side] {
                    defaults.setLastKnownSidebarWidth(width, for: side)
                }
            }
        }
        widthsToStore.removeAll()
        if let collapsed = collapsedToStore, PhiPreferences.GeneralSettings.loadSidebarCollapsed() != collapsed {
            PhiPreferences.GeneralSettings.saveSidebarCollapsed(collapsed)
        }
        collapsedToStore = nil
    }

    // MARK: - Dock hand-off

    private var sidebarHandOffRun = 0

    /// Where the pointer is, in window coordinates. A test seam.
    lazy var pointerLocationInWindow: () -> NSPoint? = { [weak self] in
        self?.view.window?.mouseLocationOutsideOfEventStream
    }

    /// The event that asked for this toggle. A test seam.
    lazy var currentEventType: () -> NSEvent.EventType? = { NSApp.currentEvent?.type }

    /// The pointer is on the open column.
    private func isPointerOnDockedSidebar() -> Bool {
        guard !transitions.isCollapsed, let point = pointerLocationInWindow() else { return false }
        let bounds = view.bounds
        let width = sidebarWidth
        let column = NSRect(x: sidebarOnRight ? bounds.maxX - width : bounds.minX, y: bounds.minY,
                            width: width, height: bounds.height)
        return view.convert(column, to: nil).contains(point)
    }

    /// Pinning from the visible floating panel docks it in place; unpinning
    /// with the shortcut while the pointer is on the column turns the column
    /// into the panel in place. Animated hand-offs group both changes.
    /// Returns false when this toggle is not a hand-off.
    ///
    /// A click on the sidebar button also has the pointer on the column, but
    /// it means put the sidebar away, so only a key press keeps it up.
    private func handOffSidebar(collapsing collapsed: Bool, animated: Bool, completion: ((Bool) -> Void)?) -> Bool {
        let kind: SidebarHandOffKind?
        if collapsed {
            kind = currentEventType() == .keyDown && isPointerOnDockedSidebar() ? .undock : nil
        } else {
            kind = floatingSidebarHost.isVisible ? .dock : nil
        }
        guard let kind, floatingSidebarHost.beginSidebarHandOff(kind) else { return false }
        sidebarHandOffRun += 1
        guard animated else {
            changeCollapsed(to: collapsed, duration: nil, widensWindow: false)
            floatingSidebarHost.finishSidebarHandOffImmediately()
            floatingSidebarHost.browserState?.windowController?.refreshTrafficLightVisibility()
            completion?(true)
            return true
        }
        let run = sidebarHandOffRun
        // The panel covers the column throughout; the column's own rows
        // would show in or out under it.
        sidebarHost.setResidentsHidden(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = FloatingSidebarHostViewController.sidebarHandOffDuration
            context.timingFunction = SidebarToggleAnimation.timingFunction
            context.allowsImplicitAnimation = true
            // A dock opens the column where the panel is, at the panel's
            // width, so the window keeps its size.
            changeCollapsed(to: collapsed, duration: FloatingSidebarHostViewController.sidebarHandOffDuration,
                            widensWindow: false, completion: completion)
            floatingSidebarHost.animateSidebarHandOff()
        } completionHandler: { [weak self] in
            // A later toggle already finished this hand-off and may run its own.
            guard let self, sidebarHandOffRun == run else { return }
            sidebarHost.setResidentsHidden(false)
            floatingSidebarHost.finishSidebarHandOff()
        }
        return true
    }
}

/// The sidebar column: the vibrancy material and themed fill every Space's
/// sidebar content shows through, and the host of that content. The
/// backdrop follows the theme of the session the column stands for —
/// normally the presented one; during a band slide the leaving one, whose
/// theme is ramping to the entering Space's colors — through
/// `BrowserThemeContextProviding`, which the views' theme lookup consults
/// on the responder chain.
///
/// Every session of the slot keeps its sidebar content *resident* here —
/// added once, sized with the column, hidden unless presented. That is what
/// lets a Space switch start on the next frame: a resident view's layers
/// exist and its layout is current, so presenting it is a flag flip, where
/// a view brought into the window on the switch pays for its layer tree,
/// its layout and the theme rebinds of everything in it first.
final class ShellSidebarHostViewController: NSViewController, BrowserThemeContextProviding {
    private(set) weak var themeSession: SpaceSessionController?

    var providedBrowserThemeContext: BrowserThemeContext? {
        themeSession?.browserState.themeContext
    }

    var backdrop: ColoredVisualEffectView { view as! ColoredVisualEffectView }

    override func loadView() {
        let view = ColoredVisualEffectView()
        view.themedBackgroundColor = .windowOverlayBackground
        view.usesThemePalette = true
        view.material = .fullScreenUI
        view.blendingMode = .behindWindow
        self.view = view
    }

    /// Points the backdrop at `session`'s theme.
    func followTheme(of session: SpaceSessionController?) {
        themeSession = session
        backdrop.rebindThemeProvider()
    }

    /// How firmly a resident's trailing edge follows the column's, and a
    /// hidden one holds its width: above every default content preference
    /// (`NSLayoutConstraint.Priority.defaultLow`), so a resident with no
    /// demand of its own spans the column exactly, and short of required, so
    /// one whose content insists on more width overruns the column, which
    /// clips it, instead of contending with the column's frame.
    static let residentTrailingPriority = NSLayoutConstraint.Priority(259)

    /// Hides the residents, leaving the backdrop, while the floating panel
    /// covers the column in a hand-off
    /// (`ShellSplitViewController.handOffSidebar(collapsing:completion:)`).
    func setResidentsHidden(_ hidden: Bool) {
        for resident in view.subviews where residentWidthConstraints[ObjectIdentifier(resident)] != nil {
            resident.alphaValue = hidden ? 0 : 1
        }
    }

    /// Makes `sidebarView` resident in the column, hidden, filling it and
    /// following its size. A view already resident is left as it is.
    ///
    /// Residents follow the column; the column never follows a resident: its
    /// frame is the split's to set (`ShellSplitView`). The leading, top and
    /// bottom edges are pinned outright and the trailing edge at
    /// `residentTrailingPriority`. A resident tree can carry a minimum width
    /// at a higher priority (an `NSHostingView` left with its default
    /// `sizingOptions` pins its SwiftUI content's minimum and maximum width
    /// at 999.9); such a tree overruns a narrower column, which is visible
    /// and fixable where it happens.
    ///
    /// Only the presented resident follows the column's width live. A hidden
    /// one holds its width (`heldWidth`, at the same priority) and catches up
    /// once the column has stopped changing: AppKit lays out hidden views
    /// too, so with every resident following, a divider drag re-laid out
    /// every Space's sidebar on every frame. They are caught up well before
    /// a switch can present one, so presenting stays a flag flip. Nothing
    /// moves a hidden resident during a toggle: the column slides by its
    /// layer, and its frame stays put.
    func host(_ sidebarView: NSView) {
        guard sidebarView.superview !== view else { return }
        sidebarView.removeFromSuperview()
        sidebarView.isHidden = true
        sidebarView.frame = view.bounds
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebarView)
        let trailing = sidebarView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        trailing.priority = Self.residentTrailingPriority
        let heldWidth = sidebarView.widthAnchor.constraint(equalToConstant: view.bounds.width)
        heldWidth.priority = Self.residentTrailingPriority
        residentWidthConstraints[ObjectIdentifier(sidebarView)] = ResidentWidthConstraints(
            trailing: trailing,
            heldWidth: heldWidth
        )
        NSLayoutConstraint.activate([
            sidebarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarView.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            heldWidth,
        ])
    }

    /// Shows a resident `sidebarView` as the column's content, above the
    /// other resident views. The reorder is a sort, not a re-add: re-adding
    /// takes the view out of the window and back, which is the cost
    /// residency exists to avoid.
    func present(_ sidebarView: NSView) {
        host(sidebarView)
        if let constraints = residentWidthConstraints[ObjectIdentifier(sidebarView)] {
            constraints.heldWidth.isActive = false
            constraints.trailing.isActive = true
        }
        sidebarView.isHidden = false
        if view.subviews.last !== sidebarView {
            let presented = Unmanaged.passUnretained(sidebarView).toOpaque()
            view.sortSubviews({ a, b, context in
                let presented = context!
                if Unmanaged.passUnretained(a).toOpaque() == presented { return .orderedDescending }
                if Unmanaged.passUnretained(b).toOpaque() == presented { return .orderedAscending }
                return .orderedSame
            }, context: presented)
        }
    }

    /// Hides a resident `sidebarView`; it stays resident for its next turn.
    func conceal(_ sidebarView: NSView) {
        guard sidebarView.superview === view else { return }
        sidebarView.isHidden = true
        if let constraints = residentWidthConstraints[ObjectIdentifier(sidebarView)] {
            constraints.heldWidth.constant = view.bounds.width
            constraints.trailing.isActive = false
            constraints.heldWidth.isActive = true
        }
    }

    /// Takes `sidebarView` out of the column for good: its session is
    /// leaving the shell.
    func evict(_ sidebarView: NSView) {
        guard sidebarView.superview === view else { return }
        // The held width is the view's own constraint and would outlive the
        // removal, following the view wherever it goes next.
        residentWidthConstraints.removeValue(forKey: ObjectIdentifier(sidebarView))?
            .heldWidth.isActive = false
        sidebarView.removeFromSuperview()
        sidebarView.translatesAutoresizingMaskIntoConstraints = true
        sidebarView.isHidden = false
    }

    private struct ResidentWidthConstraints {
        /// Follows the column; active while the resident is presented.
        let trailing: NSLayoutConstraint
        /// Holds a width; active while the resident is hidden.
        let heldWidth: NSLayoutConstraint
    }

    private var residentWidthConstraints: [ObjectIdentifier: ResidentWidthConstraints] = [:]
    private var heldWidthSyncWorkItem: DispatchWorkItem?
    /// Quiet period after the column's last width change before the hidden
    /// residents take the new width.
    private static let heldWidthSyncDelay: TimeInterval = 0.2

    override func viewDidLoad() {
        super.viewDidLoad()
        view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(columnFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: view
        )
    }

    @objc private func columnFrameDidChange(_ notification: Notification) {
        heldWidthSyncWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.heldWidthSyncWorkItem = nil
            self?.syncHeldWidths()
        }
        heldWidthSyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.heldWidthSyncDelay, execute: workItem)
    }

    /// Brings every hidden resident to the column's current width.
    private func syncHeldWidths() {
        let width = view.bounds.width
        for constraints in residentWidthConstraints.values
        where constraints.heldWidth.isActive && constraints.heldWidth.constant != width {
            constraints.heldWidth.constant = width
        }
    }
}

/// The page area: the host of the presented session's page tree
/// (`MainSplitViewController.view`), which fills it, and — like the sidebar
/// column — the painter of the themed backdrop around the page: the toolbar
/// strip and the margins. Hosted page trees paint none of their own
/// (`WebContentContainerViewController.paintsOwnBackdrop`), so a Space
/// switch ramps this one backdrop on the slide's clock, in step with the
/// column, instead of leaving the frame to the leaving tree's theme.
final class ShellContentHostViewController: NSViewController, BrowserThemeContextProviding {
    private(set) weak var themeSession: SpaceSessionController?

    var providedBrowserThemeContext: BrowserThemeContext? {
        themeSession?.browserState.themeContext
    }

    var backdrop: ColoredVisualEffectView { view as! ColoredVisualEffectView }

    override func loadView() {
        let view = ColoredVisualEffectView()
        view.themedBackgroundColor = .windowOverlayBackground
        view.usesThemePalette = true
        view.material = .fullScreenUI
        view.blendingMode = .behindWindow
        view.autoresizesSubviews = true
        self.view = view
    }

    /// Points the backdrop at `session`'s theme.
    func followTheme(of session: SpaceSessionController?) {
        themeSession = session
        backdrop.rebindThemeProvider()
    }

    /// The presented page tree's card, for a sidebar toggle's mask.
    var slidingPageCard: ShellSplitView.SlidingPageCard? {
        guard let controller = themeSession?.mainSplitViewController, controller.isViewLoaded,
              controller.view.superview === view, !controller.view.isHidden else { return nil }
        let outline = controller.webContentContainerViewController.pageCardOutline(in: controller.view)
        return ShellSplitView.SlidingPageCard(view: controller.view, frame: outline.frame,
                                              cornerRadius: outline.cornerRadius, margin: outline.margin)
    }

    /// See `WebContentContainerViewController.setSidebarInsetInFlight(_:)`.
    func setPageInsetInFlight(_ inset: CGFloat) {
        guard let controller = themeSession?.mainSplitViewController, controller.isViewLoaded else { return }
        controller.webContentContainerViewController.setSidebarInsetInFlight(inset)
    }

    /// See `WebContentContainerViewController.setBackdropPaintsPageBackground(_:)`.
    func setPageBackdropPaintsPageBackground(_ paints: Bool) {
        guard let controller = themeSession?.mainSplitViewController, controller.isViewLoaded else { return }
        controller.webContentContainerViewController.setBackdropPaintsPageBackground(paints)
    }

    /// Keep page trees attached just like sidebar content. A hidden ancestor
    /// delivers WebContentsViewCocoa.viewDidHide and Chromium kHidden without
    /// repeating the window attachment callbacks on every Space switch.
    ///
    /// Only the presented tree follows the page area's size. A hidden one
    /// keeps its frame and catches up in `install`, so a sidebar toggle or
    /// window resize doesn't lay out and resize every resident Space's page.
    func host(_ contentView: NSView) {
        guard contentView.superview !== view else { return }
        contentView.removeFromSuperview()
        contentView.isHidden = true
        contentView.frame = view.bounds
        contentView.autoresizingMask = []
        contentView.wantsLayer = true
        view.addSubview(contentView)
    }

    func install(_ contentView: NSView) {
        host(contentView)
        if contentView.frame != view.bounds { contentView.frame = view.bounds }
        contentView.autoresizingMask = [.width, .height]
        contentView.layer?.transform = CATransform3DIdentity
        contentView.isHidden = false
        if view.subviews.last !== contentView {
            let presented = Unmanaged.passUnretained(contentView).toOpaque()
            view.sortSubviews({ a, b, context in
                if Unmanaged.passUnretained(a).toOpaque() == context! { return .orderedDescending }
                if Unmanaged.passUnretained(b).toOpaque() == context! { return .orderedAscending }
                return .orderedSame
            }, context: presented)
        }
    }

    func conceal(_ contentView: NSView) {
        guard contentView.superview === view else { return }
        contentView.layer?.transform = CATransform3DIdentity
        contentView.isHidden = true
        contentView.autoresizingMask = []
    }

    func evict(_ contentView: NSView) {
        contentView.removeFromSuperview()
        contentView.isHidden = false
    }
}
