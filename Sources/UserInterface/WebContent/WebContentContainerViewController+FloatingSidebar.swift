// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit

extension WebContentContainerViewController {
    static let floatingSidebarDefaultWidth: CGFloat = MainSplitViewController.leftItemMinWidth
    static let floatingSidebarTriggerWidth: CGFloat = 10
    static let floatingSidebarHideDelay: TimeInterval = 0.12
    static let floatingSidebarMinimumVisibleDuration: TimeInterval = 0.5
    static let floatingSidebarInset: CGFloat = 5
    static let floatingSidebarShowDuration: TimeInterval = 0.15
    static let floatingSidebarHideDuration: TimeInterval = 0.15

    var currentFloatingWidth: CGFloat {
        // The floating panel only appears while the sidebar is collapsed (sidebarWidth == 0),
        // so we always rely on the cached width captured before collapse. `edgesSpacing`
        // compensates for the hidden splitview divider so the panel visually matches the
        // real sidebar.
        let baseWidth = lastKnownSidebarWidth > 0 ? lastKnownSidebarWidth : Self.floatingSidebarDefaultWidth
        return baseWidth + WebContentConstant.edgesSpacing
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
        guard floatingSidebarContainerView == nil else { return }
        guard let state = browserState else { return }

        let floatingSidebarVC = FloatingSidebarViewController(browserState: state)

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

        addChild(floatingSidebarVC)
        panelContentView.addSubview(floatingSidebarVC.view)
        floatingSidebarVC.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

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

        floatingSidebarViewController = floatingSidebarVC
        floatingSidebarVC.setContentActive(shouldEnableFloatingSidebar())
        floatingSidebarContainerView = interactionContainerView
    }

    func updateFloatingSidebarWidth() {
        floatingSidebarWidthConstraint?.update(offset: currentFloatingWidth + Self.floatingSidebarInset)
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
            // Delay enabling trigger to avoid activation during sidebar collapse animation.
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.shouldEnableFloatingSidebar() else { return }
                self.floatingSidebarTriggerView.isHidden = false
            }
            floatingSidebarEnableWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
        }
    }

    func showFloatingSidebar() {
        guard shouldEnableFloatingSidebar() else { return }
        ensureFloatingSidebarIfNeeded()
        cancelFloatingSidebarHide()

        guard let panel = floatingSidebarContainerView else { return }
        guard panel.isHidden else { return }

        // Ensure panel starts offscreen before sliding in.
        floatingSidebarLeadingConstraint?.update(offset: floatingSidebarHiddenLeading)
        view.layoutSubtreeIfNeeded()
        panel.isHidden = false
        floatingSidebarLastShownAt = Date()

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
        floatingSidebarLeadingConstraint?.update(offset: floatingSidebarHiddenLeading)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.floatingSidebarHideDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                context.allowsImplicitAnimation = true
                self.view.layoutSubtreeIfNeeded()
            } completionHandler: {
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
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
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
