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
    }

    private enum PendingDropAction {
        case local
        case external(ExternalDropTarget)
        case tearOff
    }

    // MARK: - Dependencies
    private let browserState: BrowserState
    private var cancellables = Set<AnyCancellable>()
    private let dragController = TabStripDragController()
    private var isActive = false

    // MARK: - Scroll
    private var currentScrollOffset: CGFloat = 0.0
    private var lastContentWidth: CGFloat = 0.0

    private let containerMaskLayer = CAShapeLayer()

    // MARK: - View Pools
    private var pinnedTabViews: [String: TabItemView] = [:]
    private var normalTabViews: [String: TabItemView] = [:]
    /// Reusable separator views.
    private var separatorViews: [NSView] = []
    /// Hovered normal-tab index.
    private var hoveredTabIndex: Int?

    // MARK: - Layout Lock
    /// Whether layout is temporarily locked after a tab closes.
    private var isLayoutLocked = false
    /// Cached inactive-tab width while layout is locked.
    private var lockedTabWidth: CGFloat?
    /// Previous normal-tab count, used to detect tab closes.
    private var previousNormalTabCount: Int = 0

    private struct ExternalDragPreview {
        let zone: TabContainerType
        let index: Int
        let gapWidth: CGFloat?
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
    // Real source view that still owns mouse events during the drag.
    private weak var draggingSourceView: TabItemView?
    // Container zone currently used for drag presentation styling.
    private var draggingPresentationZone: TabContainerType?
    private var dragImageWindow: NSPanel?
    private var dragImageView: NSImageView?
    private var cachedTabDragImage: NSImage?
    private var cachedPageDragImage: NSImage?
    private var externalDragPreview: ExternalDragPreview?
    private weak var externalPreviewTargetStrip: TabStrip?
    private var lastDragScreenPoint: CGPoint?
    private var pendingDropAction: PendingDropAction?

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
        let activeTab = browserState.focusingTab

        let context = dragController.context
        let externalPreview = (context == nil) ? externalDragPreview : nil
        // Resolve pinned-zone drag parameters.
        let pinnedExcluded = (context?.sourceContainerType == .pinned) ? context?.sourceIndex : nil
        let pinnedGap = (context?.targetContainerType == .pinned)
            ? context?.targetIndex
            : (externalPreview?.zone == .pinned ? externalPreview?.index : nil)
 
        // Resolve normal-zone drag parameters.
        let normalExcluded = (context?.sourceContainerType == .normal) ? context?.sourceIndex : nil
        let normalGap = (context?.targetContainerType == .normal)
            ? context?.targetIndex
            : (externalPreview?.zone == .normal ? externalPreview?.index : nil)
        let normalGapW = (context?.targetContainerType == .normal)
            ? context?.draggedTabWidth
            : (externalPreview?.zone == .normal ? externalPreview?.gapWidth : nil)

        // Pinned zone.
        updateLayoutOnly(
            container: pinnedContainer,
            viewPool: pinnedTabViews,
            tabs: pinnedTabs,
            activeTab: activeTab,
            isPinned: true,
            excludedIndex: pinnedExcluded,
            gapIndex: pinnedGap
        )

        // Normal zone.
        updateLayoutOnly(
            container: normalContainer,
            viewPool: normalTabViews,
            tabs: normalTabs,
            activeTab: activeTab,
            isPinned: false,
            excludedIndex: normalExcluded,
            gapIndex: normalGap,
            gapWidth: normalGapW
        )
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
        let activeTab = browserState.focusingTab

        updateContainer(
            container: pinnedContainer,
            viewPool: &pinnedTabViews,
            tabs: pinnedTabs,
            activeTab: activeTab,
            isPinned: true
        )

        updateContainer(
            container: normalContainer,
            viewPool: &normalTabViews,
            tabs: normalTabs,
            activeTab: activeTab,
            isPinned: false
        )
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
        clearInactiveContent()
    }

    private func syncVisibleState() {
        let pinnedTabs = browserState.pinnedTabs
        let normalTabs = browserState.normalTabs
        let activeTab = browserState.focusingTab

        pinnedContainer.layer?.backgroundColor = pinnedTabs.isEmpty
            ? NSColor.clear.cgColor
            : NSColor(resource: .sidebarTabHovered).cgColor
        previousNormalTabCount = normalTabs.count
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

        hoveredTabIndex = nil
        currentScrollOffset = 0
        lastContentWidth = 0
        previousNormalTabCount = 0
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

                // Detect tab close by watching the normal-tab count drop.
                let isTabClosed = normalTabs.count < self.previousNormalTabCount
                self.previousNormalTabCount = normalTabs.count

                // Keep widths stable when the pointer is still inside the strip.
                if isTabClosed && self.isMouseInside() {
                    self.lockLayoutIfNeeded()
                }

                self.performLayout(context: .dataChanged) {
                    if let activeTab = activeTab {
                        self.scrollToMakeTabVisible(activeTab)
                    }
                }
                self.needsLayout = true
            }
            .store(in: &cancellables)
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

        // Infer the inactive width from any tab narrower than the active minimum.
        let activeMinWidth = TabStripMetrics.Tab.activeMinWidth
        let inactiveTabWidth = normalTabViews.values
            .first { $0.frame.width < activeMinWidth }?
            .frame.width

        // If no inactive tab is compressed, there is no need to lock the layout.
        if let width = inactiveTabWidth {
            lockedTabWidth = width
            isLayoutLocked = true
        }
    }

    /// Manual layout used while widths are temporarily locked.
    private func calculateLockedLayout(
        tabs: [Tab],
        activeTab: Tab?,
        lockedInactiveWidth: CGFloat
    ) -> TabStripLayoutOutput {
        let spacing = TabStripMetrics.Tab.spacing
        let tabHeight = TabStripMetrics.Strip.tabHeight
        let activeMinWidth = TabStripMetrics.Tab.activeMinWidth
        let bottomSpacing = TabStripMetrics.Strip.bottomSpacing

        // Match the same leading offset used by the normal layout engine.
        let startOffsetX = max(0, TabStripMetrics.Tab.inverseCornerRadius - spacing)

        var tabFrames: [CGRect] = []
        var separatorXs: [CGFloat] = []
        var currentX = startOffsetX

        for tab in tabs {
            currentX += spacing

            let isActive = isTabActive(tab, activeTab: activeTab)
            let width = isActive ? activeMinWidth : lockedInactiveWidth

            let frame = CGRect(
                x: currentX,
                y: bottomSpacing,
                width: width,
                height: tabHeight
            )
            tabFrames.append(frame)

            currentX += width

            // Separator position.
            let separatorX = currentX + spacing
            separatorXs.append(separatorX)

            currentX += spacing + 1.0
        }

        currentX += spacing

        // NewTabButton
        let btnSize = TabStripMetrics.NewTabButton.size
        let newTabFrame = CGRect(
            x: currentX,
            y: bottomSpacing,
            width: btnSize.width,
            height: btnSize.height
        )

        currentX += btnSize.width + TabStripMetrics.NewTabButton.insets.right

        return TabStripLayoutOutput(
            tabFrames: tabFrames,
            separatorXPositions: separatorXs,
            newTabButtonFrame: newTabFrame,
            totalContentWidth: currentX
        )
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
        gapIndex: Int? = nil,
        gapWidth: CGFloat? = nil
    ) {
        guard let container = container else { return }

        let layoutOutput = calculateLayout(
            containerWidth: container.bounds.width,
            tabs: tabs,
            activeTab: activeTab,
            isPinned: isPinned,
            excludedIndex: excludedIndex,
            gapIndex: gapIndex,
            gapWidth: gapWidth
        )

        updateViewPool(
            container: container,
            viewPool: &viewPool,
            tabs: tabs,
            activeTab: activeTab,
            isPinned: isPinned
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
        gapIndex: Int? = nil,
        gapWidth: CGFloat? = nil
    ) -> TabStripLayoutOutput {
        if isPinned {
            return TabStripLayoutEngine.layoutPinned(
                tabCount: tabs.count,
                excludedTabIndex: excludedIndex,
                gapAtIndex: gapIndex
            )
        }

        if isLayoutLocked, let lockedWidth = lockedTabWidth {
            return calculateLockedLayout(
                tabs: tabs,
                activeTab: activeTab,
                lockedInactiveWidth: lockedWidth
            )
        } else {
            let activeIndex = tabs.firstIndex { isTabActive($0, activeTab: activeTab) }
            let input = TabStripLayoutInput(
                containerWidth: containerWidth,
                tabCount: tabs.count,
                activeTabIndex: activeIndex,
                spacing: TabStripMetrics.Tab.spacing,
                idealTabWidth: TabStripMetrics.Tab.idealWidth,
                minTabWidth: TabStripMetrics.Tab.minWidth,
                activeTabWidth: TabStripMetrics.Tab.activeMinWidth,
                tabHeight: TabStripMetrics.Strip.tabHeight,
                excludedTabIndex: excludedIndex,
                gapAtIndex: gapIndex,
                gapWidth: gapWidth
            )
            return TabStripLayoutEngine.layoutNormal(input: input)
        }
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
        isPinned: Bool
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

            let renderData = TabRenderData(
                id: id,
                title: tab.title,
                url: tab.url ?? "",
                isActive: isTabActive(tab, activeTab: activeTab),
                isPinned: isPinned,
                sourceTab: tab
            )
            view.configure(with: renderData)

            if view.alphaValue < 1.0 {
                view.animator().alphaValue = 1.0
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

            view.onSelect = { [weak self, weak tab] in
                self?.handleTabSelection(tab: tab)
            }
            if !isPinned {
                let capturedIndex = index
                view.onHoverChanged = { [weak self] isHovered in
                    guard let self = self else { return }
                    self.hoveredTabIndex = isHovered ? capturedIndex : nil
                    let output = self.calculateLayout(
                        containerWidth: self.normalContainer.bounds.width,
                        tabs: self.browserState.normalTabs,
                        activeTab: self.browserState.focusingTab,
                        isPinned: false
                    )
                    // Re-render separators because hover state affects visibility.
                    self.updateSeparators(
                        in: self.normalContainer,
                        xPositions: output.separatorXPositions,
                        tabs: self.browserState.normalTabs,
                        activeTab: self.browserState.focusingTab
                    )
                }
            }

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

        for (index, tab) in tabs.enumerated() {
            let id = tabId(for: tab)
            guard let view = viewPool[id] else { continue }

            if draggingTab != nil && tab === draggingTab {
                continue
            }

            if index < layoutOutput.tabFrames.count {
                var frame = layoutOutput.tabFrames[index]
                if !isPinned {
                    frame.origin.x -= currentScrollOffset
                }
                view.frame = frame
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

        for (index, x) in xPositions.enumerated() {
            let sep = separatorViews[index]
            // Separators only render in the normal container, but keep the check explicit.
            let finalX = (container === normalContainer) ? (x - currentScrollOffset) : x
            sep.frame = CGRect(x: finalX, y: y, width: sepSize.width, height: sepSize.height)
 
            // Hide separators adjacent to the active or hovered tab.
            var shouldHide = false

            if let activeIdx = activeIndex {
                if index == activeIdx { shouldHide = true }      // Separator on the tab's right side.
                if index == activeIdx - 1 { shouldHide = true }  // Separator on the tab's left side.
            }
            if let hoveredIdx = hoveredTabIndex {
                if index == hoveredIdx { shouldHide = true }      // Separator on the tab's right side.
                if index == hoveredIdx - 1 { shouldHide = true }  // Separator on the tab's left side.
            }

            sep.isHidden = shouldHide
        }
    }

    // MARK: - Helper Methods
    private func tabId(for tab: Tab) -> String {
        return tab.uniqueId
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

        return false
    }

    private func handleTabSelection(tab: Tab?) {
        guard let tab = tab else { return }
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

    private func finalizeDragScreenPoint() -> CGPoint? {
        let point = NSEvent.mouseLocation
        lastDragScreenPoint = CGPoint(x: point.x, y: point.y)
        return lastDragScreenPoint
    }

    private func resolveExternalDropTarget(for screenPoint: CGPoint) -> ExternalDropTarget? {
        guard let (targetWindowController, targetStrip) = visibleExternalTabStripTarget(for: screenPoint) else {
            return nil
        }
        let target = targetStrip.dropTarget(forScreenPoint: screenPoint)
        return ExternalDropTarget(
            windowController: targetWindowController,
            zone: target.zone,
            index: target.index
        )
    }

    func updateExternalDragPreview(screenPoint: CGPoint) {
        guard dragController.context == nil else { return }
        let target = dropTarget(forScreenPoint: screenPoint)
        let gapWidth = (target.zone == .normal) ? currentAverageNormalTabWidth() : nil
        let nextPreview = ExternalDragPreview(
            zone: target.zone,
            index: target.index,
            gapWidth: gapWidth
        )
        if let existing = externalDragPreview,
           existing.zone == nextPreview.zone,
           existing.index == nextPreview.index,
           existing.gapWidth == nextPreview.gapWidth {
            return
        }
        externalDragPreview = nextPreview
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func clearExternalDragPreview() {
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
        guard let context = dragController.context else {
            hideFloatingDragPreview()
            return
        }

        let shouldUsePageSnapshot = browserState.tabDraggingSession.shouldUsePageSnapshotPreview(at: screenPoint)
        if !shouldUsePageSnapshot, isInsideDragBoundary(screenPoint) {
            draggingProxyView?.alphaValue = 1
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

        let panel = ensureDragImageWindow()
        dragImageView?.image = image
        dragImageView?.frame = CGRect(origin: .zero, size: image.size)

        let frame = dragImageFrame(around: screenPoint, size: image.size)
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    private func updateExternalPreviewTarget(screenPoint: CGPoint) {
        guard dragController.context != nil else { return }
        let targetStrip = visibleExternalTabStripTarget(for: screenPoint)?.tabStrip

        if externalPreviewTargetStrip !== targetStrip {
            externalPreviewTargetStrip?.clearExternalDragPreview()
            externalPreviewTargetStrip = targetStrip
        }

        guard let targetStrip else {
            return
        }
        targetStrip.updateExternalDragPreview(screenPoint: screenPoint)
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
        return isInsideDragBoundary(screenPoint) ? .local : .tearOff
    }

    private func moveTabToWindow(
        _ tab: Tab,
        targetState: BrowserState,
        scheduleNormalInsertion: Bool,
        index: Int
    ) -> Bool {
        guard let wrapper = tab.webContentWrapper else { return false }
        if scheduleNormalInsertion {
            targetState.scheduleNormalTabInsertion(tabGuid: tab.guid, at: index)
        }
        let insertIndex = max(0, targetState.tabs.count)
        wrapper.moveSelf(toWindow: targetState.windowId.int64Value, at: insertIndex)
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
        if let view = isPinned ? pinnedTabViews[id] : normalTabViews[id] {
            // Proxy view carries drag visuals so the source view can stay out of layout flow.
            let renderData = TabRenderData(
                id: id,
                title: tab.title,
                url: tab.url ?? "",
                isActive: isTabActive(tab, activeTab: browserState.focusingTab),
                isPinned: isPinned,
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
        }
        self.dragController.startDragging(
            tab: tab,
            sourceIndex: index,
            sourceZone: isPinned ? .pinned : .normal,
            mouseLocation: mouseLoc,
            // Keep the initial frame in overlay coordinates for drag math.
            tabFrame: dragOverlay.convert(frame, from: isPinned ? pinnedContainer : normalContainer)
        )
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
        let shouldForceEnd: Bool
        switch pendingDropAction {
        case .external, .tearOff:
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

        return TabStripMetricsSnapshot(
            pinnedContainerFrame: pinnedContainer.frame,
            normalContainerFrame: normalContainer.frame,
            pinnedTabWidth: TabStripMetrics.PinnedTab.width,
            normalTabFrames: normalFrames,
            pinnedTabFrames: pinnedFrames,
            normalScrollOffset: currentScrollOffset
        )
    }

    func dragControllerDidUpdateLayout(
        pinnedExcludedIndex: Int?,
        pinnedGapIndex: Int?,
        normalExcludedIndex: Int?,
        normalGapIndex: Int?,
        normalGapWidth: CGFloat?
    ) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .default)
            ctx.allowsImplicitAnimation = true
            updateLayoutOnly(
                container: pinnedContainer,
                viewPool: pinnedTabViews,
                tabs: browserState.pinnedTabs,
                activeTab: browserState.focusingTab,
                isPinned: true,
                excludedIndex: pinnedExcludedIndex,
                gapIndex: pinnedGapIndex
            )

            updateLayoutOnly(
                container: normalContainer,
                viewPool: normalTabViews,
                tabs: browserState.normalTabs,
                activeTab: browserState.focusingTab,
                isPinned: false,
                excludedIndex: normalExcludedIndex,
                gapIndex: normalGapIndex,
                gapWidth: normalGapWidth
            )
        }

        updateDraggingViewPosition()
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

        clearDraggingPresentation(using: context)

        let isOriginalPinned = context.sourceContainerType == .pinned
        let originalIndex = context.sourceIndex

        // Perform the underlying data move first.
        if isOriginalPinned {
            if toZone == .normal {
                // Case: pinned -> normal.
                if let guid = tab.guidInLocalDB {
                    browserState.movePinnedTabOut(pinnedGuid: guid, to: toIndex, selectAfterMove: tab.isActive)
                }
            } else {
                // Case: pinned -> pinned.
                browserState.movePinnedTab(tab: tab, to: toIndex, selectAfterMove: tab.isActive)
            }
        } else {
            if toZone == .pinned {
                // Case: normal -> pinned.
                browserState.moveNormalTab(tabId: tab.guid, toPinnd: toIndex, selectAfterMove: tab.isActive)
            } else {
                browserState.moveNormalTabLocally(from: originalIndex, to: toIndex)
            }
        }

        // Then reset the UI back to a clean non-drag layout.
        performLayout(context: .dataChanged)
        browserState.tabDraggingSession.end(screenLocation: screenPoint, dragOperation: .move)
    }

    func dragControllerDidCancelDrag() {
        clearDraggingPresentation(using: nil)
        browserState.tabDraggingSession.cancel(screenLocation: lastDragScreenPoint)
        pendingDropAction = nil
        clearExternalPreviewTarget()
        // Reset drag-related UI state.
        performLayout(context: .dataChanged)
    }

    func dragControllerConvertPointToLocal(_ windowPoint: CGPoint) -> CGPoint {
        return convert(windowPoint, from: nil)
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
        excludedIndex: Int?,
        gapIndex: Int?,
        gapWidth: CGFloat? = nil
    ) {
        let layoutOutput = calculateLayout(
            containerWidth: container.bounds.width,
            tabs: tabs,
            activeTab: activeTab,
            isPinned: isPinned,
            excludedIndex: excludedIndex,
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
        var newFrame = dragPresentationFrame(for: context)

        // Apply the new frame without implicit animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        draggingView.frame = newFrame
        CATransaction.commit()
    }

    private func updateDraggingPresentationIfNeeded(for zone: TabContainerType, tab: Tab) {
        guard draggingPresentationZone != zone else { return }
        draggingPresentationZone = zone

        // Only restyle the proxy; the source view stays hidden.
        guard let draggingView = draggingProxyView else { return }
        let renderData = TabRenderData(
            id: tab.uniqueId,
            title: tab.title,
            url: tab.url ?? "",
            isActive: isTabActive(tab, activeTab: browserState.focusingTab),
            isPinned: zone == .pinned,
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
            // Pinned tabs use a fixed width and centered height.
            frame.size = CGSize(width: TabStripMetrics.PinnedTab.width, height: TabStripMetrics.PinnedTab.height)
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
        let padding: CGFloat = 6
        let minX = combinedFrame.minX + padding
        let rightLimit = min(combinedFrame.maxX, newTabButton.frame.minX) - padding
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
        // Clear proxy views and cached drag state.
        draggingProxyView?.removeFromSuperview()
        draggingProxyView = nil
        draggingSourceView = nil
        draggingPresentationZone = nil
        dragOverlay.isHidden = true
        hideFloatingDragPreview()
        cachedTabDragImage = nil
        cachedPageDragImage = nil
    }
}
