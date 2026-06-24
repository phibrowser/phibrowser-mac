// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import QuartzCore
import SnapKit

private final class SearchTabsContainerRootView: NSView {
    weak var controller: SearchTabsContainerViewController?

    override func mouseDown(with event: NSEvent) {
        guard let controller else {
            super.mouseDown(with: event)
            return
        }
        controller.handleBackgroundMouseDown(event)
    }
}

enum SearchTabsPresentation {
    case centered
    case attached(anchorView: NSView)

    var displayMode: SearchTabsPanelDisplayMode {
        switch self {
        case .centered:
            return .normal
        case .attached:
            return .compact
        }
    }
}

@MainActor
final class SearchTabsContainerViewController: NSViewController {
    private(set) var searchTabsController: SearchTabsViewController?
    private weak var parentView: EventBlockBgView?
    private weak var browserState: BrowserState?
    private weak var anchorView: NSView?
    private var cancellables = Set<AnyCancellable>()
    private var focusingTabObserver: AnyCancellable?
    private var frameChangeObserver: AnyCancellable?
    private var windowResizeObserver: AnyCancellable?
    private var isAnchored = false
    private var observedContainerSize: NSSize?

    private(set) var hasShown = false

    init(
        browserState: BrowserState,
        displayMode: SearchTabsPanelDisplayMode = .normal,
        superView: EventBlockBgView? = nil
    ) {
        self.browserState = browserState
        self.parentView = superView
        self.searchTabsController = SearchTabsViewController(browserState: browserState, displayMode: displayMode)
        super.init(nibName: nil, bundle: nil)
        searchTabsController?.didRequestDismiss = { [weak self] in
            self?.hideSearchTabs()
        }
        superView?.mouseDown = { [weak self] event in
            self?.handleBackgroundMouseDown(event)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = SearchTabsContainerRootView()
        root.controller = self
        view = root
        view.wantsLayer = true
        view.postsFrameChangedNotifications = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupSearchTabsView()
        setupContentSizeObserver()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        focusingTabObserver = nil
        frameChangeObserver = nil
        windowResizeObserver = nil
        hasShown = false
    }

    func showSearchTabs(presentation: SearchTabsPresentation = .centered) {
        guard let searchTabsView = searchTabsController?.view else {
            return
        }
        applyPresentation(presentation)
        hasShown = true
        searchTabsView.alphaValue = 1
        searchTabsController?.refresh()
        view.superview?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        updateSearchTabsFrame(searchTabsController?.contentSize ?? .zero)
        observedContainerSize = view.bounds.size
        observeFocusingTabChange()
        observeFrameChange()
        observeWindowResize()
    }

    func hideSearchTabs() {
        focusingTabObserver = nil
        frameChangeObserver = nil
        windowResizeObserver = nil
        anchorView = nil
        isAnchored = false
        hasShown = false
        observedContainerSize = nil
        searchTabsController?.view.alphaValue = 0
        parentView?.removeFromSuperview()
    }

    fileprivate func handleBackgroundMouseDown(_ event: NSEvent) {
        guard let searchTabsView = searchTabsController?.view else {
            return
        }

        let clickPointInRoot = view.convert(event.locationInWindow, from: nil)
        guard !searchTabsView.frame.contains(clickPointInRoot) else {
            return
        }

        let locationInWindow = event.locationInWindow
        guard let window = event.window else {
            hideSearchTabs()
            return
        }

        hideSearchTabs()
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            Self.forwardFirstClickToUnderlyingContent(
                at: locationInWindow,
                in: window,
                originalEvent: event
            )
        }
    }

    private func setupSearchTabsView() {
        guard let searchTabsView = searchTabsController?.view else {
            return
        }

        searchTabsView.wantsLayer = true
        searchTabsView.translatesAutoresizingMaskIntoConstraints = true
        searchTabsView.autoresizingMask = []
        searchTabsView.alphaValue = 0
        view.addSubview(searchTabsView)
    }

    private func setupContentSizeObserver() {
        searchTabsController?.$contentSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                self?.updateSearchTabsFrame(size)
            }
            .store(in: &cancellables)
    }

    private func observeFrameChange() {
        frameChangeObserver = NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: view)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }

                let currentSize = self.view.bounds.size
                let previousSize = self.observedContainerSize
                self.observedContainerSize = currentSize

                guard self.hasShown,
                      let previousSize,
                      previousSize.width > 0,
                      previousSize.height > 0,
                      previousSize != currentSize else {
                    return
                }
                self.hideSearchTabs()
            }
    }

    private func observeWindowResize() {
        guard let window = view.window else {
            return
        }

        windowResizeObserver = Publishers.Merge(
            NotificationCenter.default.publisher(
                for: NSWindow.willStartLiveResizeNotification,
                object: window
            ),
            NotificationCenter.default.publisher(
                for: NSWindow.didResizeNotification,
                object: window
            )
        )
        .sink { [weak self] _ in
            self?.hideSearchTabs()
        }
    }

    private func observeFocusingTabChange() {
        focusingTabObserver = browserState?.$focusingTab
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.hideSearchTabs()
            }
    }

    private func applyPresentation(_ presentation: SearchTabsPresentation) {
        searchTabsController?.setDisplayMode(presentation.displayMode)

        switch presentation {
        case .centered:
            anchorView = nil
            isAnchored = false
        case .attached(let anchorView):
            self.anchorView = anchorView
            isAnchored = true
        }
    }

    private func updateSearchTabsFrame(_ size: NSSize) {
        guard let searchTabsView = searchTabsController?.view else {
            return
        }

        if isAnchored, let anchorView {
            updateAnchoredSearchTabsFrame(size, anchorView: anchorView, searchTabsView: searchTabsView)
            return
        }

        let parentBounds = view.bounds
        guard parentBounds.width > 0, parentBounds.height > 0 else {
            return
        }

        let horizontalMargin: CGFloat = 16
        let verticalMargin: CGFloat = 32
        let maxWidth = max(parentBounds.width - horizontalMargin * 2, 0)
        let maxHeight = max(parentBounds.height - verticalMargin * 2, 0)
        guard maxWidth > 0, maxHeight > 0 else {
            return
        }

        let width = min(size.width, maxWidth)
        let height = min(size.height, maxHeight)
        let maximumContentHeight = searchTabsController?.maximumContentSize.height ?? size.height
        let centeredHeight = min(maximumContentHeight, maxHeight)
        let centeredTopY = (parentBounds.height + centeredHeight) / 2
        let x = max(horizontalMargin, (parentBounds.width - width) / 2)
        let y = searchTabsController?.usesFullWidthLayout == true
            ? max(verticalMargin, centeredTopY - height)
            : max(24, parentBounds.height - height - 72)
        searchTabsView.frame = NSRect(x: x, y: y, width: width, height: height)
    }

    private func updateAnchoredSearchTabsFrame(
        _ size: NSSize,
        anchorView: NSView,
        searchTabsView: NSView
    ) {
        let parentBounds = view.bounds
        guard parentBounds.width > 0, parentBounds.height > 0 else {
            return
        }

        let margin: CGFloat = 16
        let gap: CGFloat = 0
        let maxWidth = max(parentBounds.width - margin * 2, 0)
        let maxHeight = max(parentBounds.height - margin * 2, 0)
        let width = min(size.width, maxWidth)
        let height = min(size.height, maxHeight)
        let anchorFrame = view.convert(anchorView.bounds, from: anchorView)

        let horizontalOverlap: CGFloat = 12
        let proposedX = anchorFrame.maxX - horizontalOverlap
        let x = max(margin, min(proposedX, parentBounds.width - width - margin))

        let belowY = anchorFrame.minY - gap - height
        let aboveY = anchorFrame.maxY + gap
        let proposedY = belowY >= margin ? belowY : aboveY
        let y = max(margin, min(proposedY, parentBounds.height - height - margin))

        searchTabsView.frame = NSRect(x: x, y: y, width: width, height: height)
    }

    private static func forwardFirstClickToUnderlyingContent(
        at locationInWindow: NSPoint,
        in window: NSWindow,
        originalEvent: NSEvent
    ) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let windowNumber = window.windowNumber
        let flags = originalEvent.modifierFlags
        let clickCount = originalEvent.clickCount
        let eventNumber = originalEvent.eventNumber
        let pressureDown = originalEvent.pressure

        guard let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: flags,
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: pressureDown
        ) else { return }

        guard let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: locationInWindow,
            modifierFlags: flags,
            timestamp: timestamp + 0.02,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: 0
        ) else { return }

        window.sendEvent(mouseDown)
        window.sendEvent(mouseUp)
    }
}
